const std = @import("std");
const arch = @import("arch");

pub const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

pub const Atom = struct {
    id: u32,
    pos: Point,

    fn order(s: Atom, other: Atom) std.math.Order {
        return switch (std.math.order(s.pos.x, other.pos.x)) {
            .eq => std.math.order(s.pos.y, other.pos.y),
            else => |o| o,
        };
    }

    pub fn isLeftOf(s: Atom, other: Atom) bool {
        return s.order(other) == .lt;
    }

    pub fn isRightOf(s: Atom, other: Atom) bool {
        return s.order(other) == .gt;
    }
};

pub const Point = struct {
    x: i32,
    y: i32,
};

/// A storage-zone trap by grid index: occupancy[row][col] in the upstream
/// atom-rearrangement handoff maps to trap (grid.x(col), grid.y(row)).
pub const Site = struct {
    row: u32,
    col: u32,
};

pub const RamanTarget = struct { qubit: u32, pos: Point };
const Raman = struct { angle: f64, phase: f64, targets: []const RamanTarget };

/// One single-qubit rotation request, as handed over by the driver
/// (a front-end U gate maps theta -> angle, phi -> phase).
pub const RamanGate = struct { qubit: u32, angle: f64, phase: f64 };

const Load = struct { qubit: u32, position: Point };
const Store = struct { qubit: u32, position: Point };
const Move = struct { qubit: u32, src: Point, dest: Point };
const Rydberg = struct { zone: Zone };
const Measure = struct { zone: Zone, qubits: []u32 };

pub const OpKind = union(enum) {
    raman: Raman,
    load: Load,
    move: Move,
    store: Store,
    rydberg: Rydberg,
    measure: Measure,
};

/// All ops that execute in parallel during one timestep. The frame's index
/// in Hardware.frames is the timestep.
pub const Frame = std.ArrayList(OpKind);

pub const Hardware = struct {
    // Scratch for schedule construction (work lists, occupancy sets).
    gpa: std.mem.Allocator,

    // Owns everything the schedule hands out: frames, op payloads,
    // placement, initial. deinit is one arena teardown.
    arena: std.heap.ArenaAllocator,

    cfg: arch.ArchConfig,

    // Ops grouped by timestep; frame index == timestep.
    frames: std.ArrayList(Frame) = .empty,

    // Working position of each qubit (index = qubit id); mutated as atoms move.
    placement: []Atom = &.{},

    // Starting storage-zone position of each qubit, frozen at placement time.
    initial: []Point = &.{},

    // Current timestep. Never touch directly: emit() stamps it, step() advances it.
    t: u32 = 0,

    // Place qubits in storage zone. With `initial_sites` (the occupancy
    // delivered by the upstream Atom Assembly / Atom Rearrangement package)
    // qubit ids follow the given site order; without it, a procedural
    // fallback fills the center half of the grid, compute-facing row first.
    pub fn init(gpa: std.mem.Allocator, cfg: arch.ArchConfig, num_qubits: usize, initial_sites: ?[]const Site) !Hardware {
        const grid = cfg.storage_zone.grid();
        const num_col = grid.num_col;
        const num_row = grid.num_row;

        var sites: std.ArrayList(Point) = .empty;
        defer sites.deinit(gpa);

        if (initial_sites) |list| {
            for (list) |site| {
                if (site.row >= num_row or site.col >= num_col) return error.SiteOutsideGrid;
                try sites.append(gpa, Point{
                    .x = grid.x(site.col),
                    .y = grid.y(site.row),
                });
            }
        } else {
            // Center half: columns from 25% to 75% of the grid width.
            const col_start = num_col / 4;
            const col_end = num_col - num_col / 4;

            for (0..num_row) |row| {
                const i = num_row - 1 - row;
                for (col_start..col_end) |j| {
                    try sites.append(gpa, Point{
                        .x = grid.x(j),
                        .y = grid.y(i),
                    });
                }
            }
        }

        // The loading window only has so many sites; reject oversubscription
        // here instead of indexing past `sites` below.
        if (num_qubits > sites.items.len) return error.TooManyQubits;

        var hw = Hardware{ .gpa = gpa, .arena = .init(gpa), .cfg = cfg };
        errdefer hw.arena.deinit();
        const a = hw.arena.allocator();

        const plc = try a.alloc(Atom, num_qubits);
        for (plc, 0..) |*p, i| {
            p.* = .{ .id = @intCast(i), .pos = sites.items[i] };
        }
        hw.placement = plc;
        hw.initial = try a.alloc(Point, hw.placement.len);
        for (hw.placement, hw.initial) |atom, *p| p.* = atom.pos;

        return hw;
    }

    pub fn deinit(s: *Hardware) void {
        s.arena.deinit();
    }

    // ── Timestep management ──────────────────────────────────────────────
    // Everything emitted between two step() calls executes in parallel in
    // one frame. step() closes the current frame; it is a no-op while the
    // frame is empty, so frames are never empty and never collide.

    fn emit(s: *Hardware, kind: OpKind) !void {
        const a = s.arena.allocator();
        if (s.frames.items.len <= s.t) try s.frames.append(a, .empty);
        try s.frames.items[s.t].append(a, kind);
    }

    fn step(s: *Hardware) void {
        if (s.frames.items.len > s.t) s.t += 1;
    }

    // Load an atom into the AOD at its current position.
    fn loadAtom(s: *Hardware, a: *const Atom) !void {
        try s.emit(.{ .load = .{ .qubit = a.id, .position = a.pos } });
    }

    // Deposit an atom into the SLM at its current position (leaves the AOD).
    fn storeAtom(s: *Hardware, a: *const Atom) !void {
        try s.emit(.{ .store = .{ .qubit = a.id, .position = a.pos } });
    }

    // Displace an atom; its placement position tracks the move.
    fn moveAtom(s: *Hardware, a: *Atom, dx: i32, dy: i32) !void {
        const src = a.pos;
        a.pos.x += dx;
        a.pos.y += dy;
        try s.emit(.{ .move = .{ .qubit = a.id, .src = src, .dest = a.pos } });
    }

    // ── Schedule construction ────────────────────────────────────────────

    pub fn moveSlmCompute(s: *Hardware, fixed: []const ?usize) !void {
        var ordered: std.ArrayList(usize) = .empty;
        defer ordered.deinit(s.gpa);

        var cols: std.ArrayList(usize) = .empty;
        defer cols.deinit(s.gpa);

        for (fixed, 0..) |maybe_qubit, col| {
            if (maybe_qubit) |q| {
                try ordered.append(s.gpa, q);
                try cols.append(s.gpa, col);
            }
        }

        var register = try s.pickup(ordered.items);
        defer register.deinit(s.gpa);

        // Move each atom to its destination slot in compute zone slms[0].
        const grid = s.cfg.compute_zone.grid(0);
        const d = grid.halfSepX();

        // Manhattan step 1: move each atom to its target x column (null slots skipped).
        for (register.items, cols.items) |a, col| {
            try s.moveAtom(a, grid.x(col) - a.pos.x + d, 0);
        }
        s.step();

        // Manhattan step 2: move all atoms to the compute zone's top row —
        // gates pack into the top-left corner, nearest the storage corridor.
        const y_dest = grid.y(0);
        for (register.items) |a| {
            try s.moveAtom(a, 0, y_dest - a.pos.y);
        }
        s.step();

        // Manhattan step 3: x correction to target column, then place atom into compute SLM.
        for (register.items) |a| {
            try s.moveAtom(a, -d, 0);
            try s.storeAtom(a);
        }
        s.step();
    }

    pub fn moveSlmStorage(s: *Hardware, fixed: []const ?usize) !void {
        // Half compute zone site spacing — used as clearance from trap sites.
        const d_c = s.cfg.compute_zone.grid(0).halfSepX();
        const sgrid = s.cfg.storage_zone.grid();
        // Bottom edge of the storage zone (bottom SLM row y, closest to compute).
        const y_storage_bottom = sgrid.bottomRowY();
        const y_corridor = s.cfg.corridorY();

        // Load each atom into the AOD so the horizontal highlight shows during the return trip.
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| try s.loadAtom(&s.placement[q]);
        }
        s.step();

        // Step 2: move LEFT by d_c — rigid shift into the inter-column lane.
        // Shifting by exactly d_c places every atom at an x midpoint between compute
        // columns, so they won't cross a trap site x-column when rising in step 3.
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| try s.moveAtom(&s.placement[q], d_c, 0);
        }
        s.step();

        // Step 3: move UP to the inter-zone corridor.
        // Atoms travel vertically at inter-column x positions, clearing all compute
        // zone trap rows without crossing any trap site.
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| {
                const a = &s.placement[q];
                if (a.pos.y == y_corridor) continue;
                try s.moveAtom(a, 0, y_corridor - a.pos.y);
            }
        }
        s.step();

        // Step 4: compress — atoms move to sequential storage columns in left-to-right order,
        // skipping columns already occupied by atoms that stayed in the storage zone.
        var returning: std.ArrayList(usize) = .empty;
        defer returning.deinit(s.gpa);
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| try returning.append(s.gpa, q);
        }

        var occ = try occupiedStorageX(s.gpa, returning.items, s.placement, y_storage_bottom);
        defer occ.deinit();

        var col: usize = 0;
        for (returning.items) |q| {
            while (occ.contains(sgrid.x(col))) col += 1;

            const a = &s.placement[q];
            const dest_x = sgrid.x(col);
            if (a.pos.x != dest_x) try s.moveAtom(a, dest_x - a.pos.x, 0);
            col += 1;
        }
        s.step();

        // Step 5: drop to the bottom storage row and emit a Store op to mark the atom
        // as back in the SLM (no longer in the AOD).
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| {
                const a = &s.placement[q];
                if (a.pos.y != y_storage_bottom) {
                    try s.moveAtom(a, 0, y_storage_bottom - a.pos.y);
                }
                try s.storeAtom(a);
            }
        }
        s.step();
    }

    pub fn moveAodStorage(s: *Hardware, aod_qubits: [][]?usize) !void {
        // Collect all unique qubit IDs across all timeframes.
        var seen = std.AutoHashMap(usize, void).init(s.gpa);
        defer seen.deinit();

        var unique: std.ArrayList(usize) = .empty;
        defer unique.deinit(s.gpa);

        for (aod_qubits) |row| {
            for (row) |maybe_q| {
                if (maybe_q) |q| {
                    const gop = try seen.getOrPut(q);
                    if (!gop.found_existing) try unique.append(s.gpa, q);
                }
            }
        }
        if (unique.items.len == 0) return;

        // Sort by current x so sequential column assignments preserve left-to-right order.
        const plc = s.placement;
        std.sort.block(usize, unique.items, plc, struct {
            fn lt(p: []const Atom, a: usize, b: usize) bool {
                return p[a].pos.x < p[b].pos.x;
            }
        }.lt);

        // Load each atom into the AOD so the horizontal highlight shows during the return trip.
        for (unique.items) |q| try s.loadAtom(&s.placement[q]);
        s.step();

        const d_c = s.cfg.compute_zone.grid(0).halfSepX();
        const sgrid = s.cfg.storage_zone.grid();
        const y_storage_bottom = sgrid.bottomRowY();
        const y_corridor = s.cfg.corridorY();

        // Step 1: move RIGHT by d_c — shift into inter-column lane.
        for (unique.items) |q| try s.moveAtom(&s.placement[q], d_c, 0);
        s.step();

        // Step 2: move UP to the inter-zone corridor.
        for (unique.items) |q| {
            const a = &s.placement[q];
            if (a.pos.y == y_corridor) continue;
            try s.moveAtom(a, 0, y_corridor - a.pos.y);
        }
        s.step();

        // Step 3: compress — sequential storage columns in left-to-right order,
        // skipping columns already occupied by atoms that stayed in the storage zone.
        var occ = try occupiedStorageX(s.gpa, unique.items, s.placement, y_storage_bottom);
        defer occ.deinit();

        var col: usize = 0;
        for (unique.items) |q| {
            while (occ.contains(sgrid.x(col))) col += 1;

            const a = &s.placement[q];
            const dest_x = sgrid.x(col);
            if (a.pos.x != dest_x) try s.moveAtom(a, dest_x - a.pos.x, 0);
            col += 1;
        }
        s.step();

        // Step 4: drop to the bottom storage row and emit a Store op to mark the atom
        // as back in the SLM (no longer in the AOD).
        for (unique.items) |q| {
            const a = &s.placement[q];
            if (a.pos.y != y_storage_bottom) {
                try s.moveAtom(a, 0, y_storage_bottom - a.pos.y);
            }
            try s.storeAtom(a);
        }
        s.step();
    }

    // Every AOD qubit occupies a slot in every timeframe (active or
    // resting), so the first row fixes both the pickup order and each
    // atom's entry column: atoms are stored directly at their first
    // timeframe positions, and the first sweep iteration degenerates
    pub fn moveAodCompute(s: *Hardware, moveable: [][]?usize) !void {
        if (moveable.len == 0) return;

        // to the Rydberg pulse alone.
        var ordered: std.ArrayList(usize) = .empty;
        defer ordered.deinit(s.gpa);

        var cols: std.ArrayList(usize) = .empty;
        defer cols.deinit(s.gpa);

        for (moveable[0], 0..) |maybe_q, col| {
            if (maybe_q) |q| {
                try ordered.append(s.gpa, q);
                try cols.append(s.gpa, col);
            }
        }
        if (ordered.items.len == 0) return;

        // Pick up atoms from storage, traversing without crossing occupied sites.
        var register = try s.pickup(ordered.items);
        defer register.deinit(s.gpa);

        // Manhattan entry into SLM[1] — mirrors moveSlmCompute for SLM[0].
        const grid = s.cfg.compute_zone.grid(1);
        const d = grid.halfSepX();

        // Step 1: move each atom to its first-timeframe column x + d
        // (inter-column offset avoids crossings).
        for (register.items, cols.items) |a, col| {
            try s.moveAtom(a, grid.x(col) - a.pos.x + d, 0);
        }
        s.step();

        // Step 2: drop all atoms to SLM[1]'s top row, pairing with the fixed
        // atoms in SLM[0]'s top row.
        const y_dest = grid.y(0);
        for (register.items) |a| {
            try s.moveAtom(a, 0, y_dest - a.pos.y);
        }
        s.step();

        // Step 3: slide left d to land on column x, then place into compute SLM.
        for (register.items) |a| {
            try s.moveAtom(a, -d, 0);
            try s.storeAtom(a);
        }
        s.step();

        // Sweep: for each timeframe, lift atoms into AOD (t), slide to column (t),
        // then deposit back into SLM (t+1, red flash). Rows where nothing
        // moves emit nothing, so they consume no timestep.
        for (moveable) |row| {
            var moved_q: std.ArrayList(usize) = .empty;
            defer moved_q.deinit(s.gpa);

            var has_qubit = false;
            for (row, 0..) |maybe_q, i| {
                if (maybe_q) |q| {
                    has_qubit = true;
                    const a = &s.placement[q];
                    const dest_x = grid.x(i);
                    if (a.pos.x == dest_x) continue;

                    try s.loadAtom(a);
                    try s.moveAtom(a, dest_x - a.pos.x, 0);
                    try moved_q.append(s.gpa, q);
                }
            }
            s.step();

            for (moved_q.items) |q| try s.storeAtom(&s.placement[q]);
            s.step();

            // This timeframe's pairs now sit within blockade range of their
            // partners: fire the entangling pulse for this color class.
            // Conflicting CZs live in different rows, so one pulse per row.
            if (has_qubit) {
                try s.emit(.{ .rydberg = .{ .zone = .compute } });
                s.step();
            }
        }
    }

    // Apply single-qubit rotations as Raman pulses at the atoms' current
    // storage-zone positions. All gates of the batch fire in one timestep.
    pub fn raman(s: *Hardware, gates: []const RamanGate) !void {
        // FIXME, do we need a list of targets?
        for (gates) |gate| {
            const targets = try s.arena.allocator().alloc(RamanTarget, 1);
            targets[0] = .{
                .qubit = gate.qubit,
                .pos = s.placement[gate.qubit].pos,
            };

            try s.emit(.{
                .raman = .{
                    .angle = gate.angle,
                    .phase = gate.phase,
                    .targets = targets,
                },
            });
        }
        s.step();
    }

    // Shuttle every atom from the storage zone to the readout zone:
    // fan out across the compute zone's trap-free inter-column lanes,
    // descend through the zone, then park at sequential readout columns.
    //
    // Gated atoms come home to the bottom storage row, but idle atoms
    // still sit wherever assembly delivered them, possibly on several
    // rows — and the AOD drives a single row tone, so the register makes
    // one trip per occupied storage row. Rows nearest the compute zone
    // empty first, so later descents cross only vacated trap rows.
    pub fn moveReadout(s: *Hardware) !void {
        if (s.placement.len == 0) return;

        // Sort by row (compute-facing bottom row first), then by x so
        // sequential lane and column assignment preserves the AOD's
        // left-to-right order within each trip.
        const order = try s.gpa.alloc(usize, s.placement.len);
        defer s.gpa.free(order);
        for (order, 0..) |*q, i| q.* = i;
        std.sort.block(usize, order, s.placement, struct {
            fn lt(p: []const Atom, a: usize, b: usize) bool {
                if (p[a].pos.y != p[b].pos.y) return p[a].pos.y > p[b].pos.y;
                return p[a].pos.x < p[b].pos.x;
            }
        }.lt);

        const cgrid = s.cfg.compute_zone.grid(0);
        const d_c = cgrid.halfSepX();
        const rgrid = s.cfg.readout_zone.grid();
        const y_readout = rgrid.y(0);

        var start: usize = 0;
        while (start < order.len) {
            const row_y = s.placement[order[start]].pos.y;
            var end = start;
            while (end < order.len and s.placement[order[end]].pos.y == row_y) end += 1;
            const trip = order[start..end];

            for (trip) |q| try s.loadAtom(&s.placement[q]);
            s.step();

            // Step 1: fan out, one inter-column lane per atom. Lanes sit at
            // half-sep right of each compute column, so the descent crosses
            // no trap sites. Lane indices continue across trips, keeping the
            // slide to column `i` clear of atoms already parked at columns
            // below it.
            for (trip, start..) |q, i| {
                const a = &s.placement[q];
                const lane_x = cgrid.x(i) + d_c;
                if (a.pos.x != lane_x) try s.moveAtom(a, lane_x - a.pos.x, 0);
            }
            s.step();

            // Step 2: descend through the compute zone to the readout row.
            for (trip) |q| {
                const a = &s.placement[q];
                if (a.pos.y != y_readout) try s.moveAtom(a, 0, y_readout - a.pos.y);
            }
            s.step();

            // Step 3: slide to sequential readout columns and deposit.
            for (trip, start..) |q, i| {
                const a = &s.placement[q];
                const dest_x = rgrid.x(i);
                if (a.pos.x != dest_x) try s.moveAtom(a, dest_x - a.pos.x, 0);
                try s.storeAtom(a);
            }
            s.step();

            start = end;
        }
    }

    // Read out every qubit at its current position.
    pub fn measure(s: *Hardware, zone: Zone) !void {
        const qubits = try s.arena.allocator().alloc(u32, s.placement.len);
        for (qubits, 0..) |*q, i| q.* = @intCast(i);
        try s.emit(.{
            .measure = .{
                .zone = zone,
                .qubits = qubits,
            },
        });
        s.step();
    }

    // Pick up atoms from storage in `ord` order, traversing without
    // crossing occupied sites. The physical AOD drives a single row tone,
    // so the register holds one shared y at every step; only the column
    // (x) tones move per-atom. Atoms in other storage rows are reached by
    // riding the whole register to their row.
    fn pickup(s: *Hardware, ord: []const usize) !Register {
        // Every picked-up atom occupies its own AOD column.
        if (ord.len > s.cfg.aod.max_num_col) return error.AodCapacityExceeded;

        const sgrid = s.cfg.storage_zone.grid();
        const d = sgrid.halfSepX();

        var register: Register = .empty;
        errdefer register.deinit(s.gpa);

        if (ord.len == 0) return register;

        // Sites occupied by atoms not (yet) in the register. Unregistered
        // atoms never move during pickup, so removal on pickup keeps the
        // set exact.
        var occupied = std.AutoHashMap(Point, void).init(s.gpa);
        defer occupied.deinit();
        for (s.placement) |atom| try occupied.put(atom.pos, {});

        // Pick up first atom.
        try s.pickUpAtom(&register, &occupied, &s.placement[ord[0]]);
        s.step();
        var front = s.placement[ord[0]];

        // Move the registered atoms to always make the
        // next qubit the front of the row.
        for (ord[1..]) |q| {
            const next = s.placement[q];

            if (next.pos.y != front.pos.y) {
                try s.rideRegister(&register, next.pos.x, next.pos.y);
            } else if (next.isLeftOf(front)) {
                const dx: i32 = front.pos.x - next.pos.x;
                for (register.items) |a| try s.moveAtom(a, 0, -d); // up
                s.step();
                for (register.items) |a| try s.moveAtom(a, -(dx + d), 0); // left
                s.step();
                // Before descending, shift any atom that would land on an occupied site.
                var conflict = true;
                while (conflict) {
                    conflict = false;
                    for (register.items) |a| {
                        if (occupied.contains(.{ .x = a.pos.x, .y = a.pos.y + d })) {
                            try s.moveAtom(a, -d, 0);
                            conflict = true;
                        }
                    }
                    s.step(); // no-op when there was no conflict
                }
                for (register.items) |a| try s.moveAtom(a, 0, d); // down
                s.step();
            }

            try s.pickUpAtom(&register, &occupied, &s.placement[q]);
            s.step();
            front = next;
        }

        // Stage the register in the trap-free band past the bottom storage
        // row. From the bottom row that is a plain drop; from any other row
        // the descent crosses trap rows, so ride instead.
        const y_stage = sgrid.bottomRowY() + 4 * d;
        if (front.pos.y == sgrid.bottomRowY()) {
            for (register.items) |a| try s.moveAtom(a, 0, y_stage - a.pos.y);
            s.step();
        } else {
            try s.rideRegister(&register, front.pos.x, y_stage);
        }

        return register;
    }

    // Carries the whole register to `dest_y` in three steps: hover into the
    // trap-free lane above the current row, pack the columns into the
    // half-lanes left of `anchor_x`, then ride down/up as one row. Packing
    // assigns lanes in current x order, so no two AOD columns cross; the
    // half-lane x means the vertical ride crosses no trap site, whatever
    // rows it passes. The register's shared y is preserved throughout.
    fn rideRegister(s: *Hardware, register: *Register, anchor_x: i32, dest_y: i32) !void {
        const sgrid = s.cfg.storage_zone.grid();
        const d = sgrid.halfSepX();

        for (register.items) |a| try s.moveAtom(a, 0, -d);
        s.step();

        const sorted = try s.gpa.dupe(*Atom, register.items);
        defer s.gpa.free(sorted);
        std.sort.block(*Atom, sorted, {}, struct {
            fn lt(_: void, a: *const Atom, b: *const Atom) bool {
                return a.pos.x < b.pos.x;
            }
        }.lt);
        for (sorted, 0..) |a, i| {
            const back: i32 = @intCast(sorted.len - 1 - i);
            const dest_x = anchor_x - d - back * sgrid.sep_nm[0];
            if (a.pos.x != dest_x) try s.moveAtom(a, dest_x - a.pos.x, 0);
        }
        s.step();

        for (register.items) |a| try s.moveAtom(a, 0, dest_y - a.pos.y);
        s.step();
    }

    fn pickUpAtom(
        s: *Hardware,
        register: *Register,
        occupied: *std.AutoHashMap(Point, void),
        atom: *Atom,
    ) !void {
        try s.loadAtom(atom);
        try register.append(s.gpa, atom);
        _ = occupied.remove(atom.pos);
    }
};

/// Indexed by qubit id; null means the atom hasn't been picked up.
/// Backed by a single allocation sized to the number of sites.
pub const Register = std.ArrayList(*Atom);

// Returns a set of x coordinates at `y_target` occupied by atoms whose placement
// index is NOT in `returning`. Caller must deinit the returned map.
fn occupiedStorageX(
    gpa: std.mem.Allocator,
    returning: []const usize,
    placement: []const Atom,
    y_target: i32,
) !std.AutoHashMap(i32, void) {
    var ret_set = std.AutoHashMap(usize, void).init(gpa);
    defer ret_set.deinit();
    for (returning) |q| try ret_set.put(q, {});
    var occ = std.AutoHashMap(i32, void).init(gpa);
    for (placement, 0..) |atom, i| {
        if (ret_set.contains(i)) continue;
        if (atom.pos.y == y_target) try occ.put(atom.pos.x, {});
    }
    return occ;
}

var test_no_slms: [0]arch.Slm = .{};

test "init rejects more qubits than loading-window sites" {
    const slm = arch.Slm{
        .slm_id = 0,
        .num_row = 1,
        .num_col = 4,
        .sep_nm = .{ 1000, 1000 },
        .offset_nm = .{ 0, 0 },
    };

    const cfg = arch.ArchConfig{
        .platform = .{ .name = "test", .version = "0" },
        .aod = .{
            .aod_id = 0,
            .min_sep_nm = 100,
            .max_num_row = 1,
            .max_num_col = 4,
        },
        .storage_zone = .{
            .zone_id = 0,
            .offset_nm = .{ 0, 0 },
            .dimension_nm = .{ 4000, 1000 },
            .slm = slm,
        },
        .compute_zone = .{
            .zone_id = 1,
            .offset_nm = .{ 0, 5000 },
            .dimension_nm = .{ 4000, 1000 },
            .dr_nm = 200,
            .dw_nm = 1000,
            .slms = &test_no_slms,
        },
        .readout_zone = .{
            .zone_id = 2,
            .offset_nm = .{ 0, 9000 },
            .dimension_nm = .{ 4000, 1000 },
            .slm = slm,
        },
        .constraints = .{
            .db_nm = 300,
            .dz_nm = 100,
            .one_qubit_gate_fidelity = 1,
            .two_qubit_gate_fidelity = 1,
            .readout_fidelity = 1,
        },
    };

    // The center-half window of a 1x4 grid is columns 1..3: two sites.
    try std.testing.expectError(
        error.TooManyQubits,
        Hardware.init(std.testing.allocator, cfg, 3, null),
    );

    // Explicit sites lift the center-half restriction: all 4 columns usable.
    var hw = try Hardware.init(std.testing.allocator, cfg, 3, &.{
        .{ .row = 0, .col = 0 },
        .{ .row = 0, .col = 1 },
        .{ .row = 0, .col = 3 },
    });
    defer hw.deinit();
    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, hw.initial[0]);
    try std.testing.expectEqual(Point{ .x = 1000, .y = 0 }, hw.initial[1]);
    try std.testing.expectEqual(Point{ .x = 3000, .y = 0 }, hw.initial[2]);

    // But fewer sites than qubits is still oversubscription...
    try std.testing.expectError(
        error.TooManyQubits,
        Hardware.init(std.testing.allocator, cfg, 3, &.{
            .{ .row = 0, .col = 0 },
            .{ .row = 0, .col = 1 },
        }),
    );

    // ...and a site index outside the trap grid is rejected.
    try std.testing.expectError(
        error.SiteOutsideGrid,
        Hardware.init(std.testing.allocator, cfg, 1, &.{.{ .row = 1, .col = 0 }}),
    );
}

var test_compute_slms = [2]arch.Slm{
    .{ .slm_id = 1, .num_row = 2, .num_col = 4, .sep_nm = .{ 3000, 2000 }, .offset_nm = .{ 0, 0 } },
    .{ .slm_id = 2, .num_row = 2, .num_col = 4, .sep_nm = .{ 3000, 2000 }, .offset_nm = .{ 0, 500 } },
};

// Small three-zone config for shuttling tests: 3x4 storage grid, two
// compute SLMs, one readout row.
fn testShuttleCfg() arch.ArchConfig {
    return .{
        .platform = .{ .name = "test", .version = "0" },
        .aod = .{ .aod_id = 0, .min_sep_nm = 500, .max_num_row = 1, .max_num_col = 8 },
        .storage_zone = .{
            .zone_id = 0,
            .offset_nm = .{ 0, 0 },
            .dimension_nm = .{ 4000, 3000 },
            .slm = .{ .slm_id = 0, .num_row = 3, .num_col = 4, .sep_nm = .{ 1000, 1000 }, .offset_nm = .{ 0, 0 } },
        },
        .compute_zone = .{
            .zone_id = 1,
            .offset_nm = .{ 0, 6000 },
            .dimension_nm = .{ 12000, 4000 },
            .dr_nm = 500,
            .dw_nm = 2500,
            .slms = &test_compute_slms,
        },
        .readout_zone = .{
            .zone_id = 2,
            .offset_nm = .{ 0, 12000 },
            .dimension_nm = .{ 4000, 1000 },
            .slm = .{ .slm_id = 3, .num_row = 1, .num_col = 4, .sep_nm = .{ 1000, 1000 }, .offset_nm = .{ 0, 0 } },
        },
        .constraints = .{
            .db_nm = 1000,
            .dz_nm = 1000,
            .one_qubit_gate_fidelity = 1,
            .two_qubit_gate_fidelity = 1,
            .readout_fidelity = 1,
        },
    };
}

// Replays `frames`, asserting that all AOD-held atoms share one y at the
// end of every frame (the physical AOD drives a single row tone). Returns
// the held set so callers can also assert on the terminal state.
fn expectSingleAodRow(gpa: std.mem.Allocator, frames: []const Frame) !std.AutoHashMap(u32, i32) {
    var in_aod = std.AutoHashMap(u32, i32).init(gpa);
    errdefer in_aod.deinit();

    for (frames) |frame| {
        for (frame.items) |op| switch (op) {
            .load => |l| try in_aod.put(l.qubit, l.position.y),
            .store => |st| _ = in_aod.remove(st.qubit),
            .move => |m| if (in_aod.contains(m.qubit)) try in_aod.put(m.qubit, m.dest.y),
            else => {},
        };

        var row_y: ?i32 = null;
        var it = in_aod.valueIterator();
        while (it.next()) |y| {
            if (row_y) |expected| {
                try std.testing.expectEqual(expected, y.*);
            } else row_y = y.*;
        }
    }
    return in_aod;
}

test "pickup keeps the AOD register in a single row across storage rows" {
    const gpa = std.testing.allocator;
    const cfg = testShuttleCfg();

    // Square-ish assembly: two atoms per storage row. The pickup order
    // (0, 1, 2, 3) forces a same-row advance, a row change, and a final
    // descent from a non-bottom row.
    var hw = try Hardware.init(gpa, cfg, 4, &.{
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 2 },
        .{ .row = 1, .col = 1 },
        .{ .row = 1, .col = 3 },
    });
    defer hw.deinit();

    try hw.moveSlmCompute(&.{ 0, 1, 2, 3 });

    var in_aod = try expectSingleAodRow(gpa, hw.frames.items);
    defer in_aod.deinit();
}

// Idle atoms can sit on any storage row at measurement time; readout
// shuttling must still keep the single-row-tone register on one y, so
// it makes one trip per occupied storage row.
test "moveReadout keeps the AOD register in a single row across storage rows" {
    const gpa = std.testing.allocator;

    var hw = try Hardware.init(gpa, testShuttleCfg(), 4, &.{
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 2 },
        .{ .row = 0, .col = 1 },
        .{ .row = 0, .col = 3 },
    });
    defer hw.deinit();

    try hw.moveReadout();

    var in_aod = try expectSingleAodRow(gpa, hw.frames.items);
    defer in_aod.deinit();

    // Every atom parked on the readout row, none left in the AOD.
    try std.testing.expectEqual(0, in_aod.count());
    const y_readout = hw.cfg.readout_zone.grid().y(0);
    for (hw.placement) |a| try std.testing.expectEqual(y_readout, a.pos.y);
}

// Replays `frames` and, at the k-th rydberg pulse, asserts every intended
// pair of the k-th occupied timeframe — (fixed[i], moveable[t][i]) — sits
// within the blockade radius. The verifier cannot check this: it rejects
// crowding (more than one neighbour in range), not a pair parked too far
// apart to interact, so the pairing contract is pinned here.
fn expectRydbergPairsWithinBlockade(
    cfg: arch.ArchConfig,
    hw: *const Hardware,
    fixed: []const ?usize,
    moveable: []const []?usize,
) !void {
    const gpa = std.testing.allocator;
    const pos = try gpa.alloc(Point, hw.initial.len);
    defer gpa.free(pos);
    @memcpy(pos, hw.initial);

    const db: i64 = cfg.constraints.db_nm;
    var pulse: usize = 0;

    for (hw.frames.items) |frame| {
        for (frame.items) |op| switch (op) {
            .move => |m| pos[m.qubit] = m.dest,
            .rydberg => {
                var seen: usize = 0;
                const row = for (moveable) |r| {
                    const occupied = for (r) |q| {
                        if (q != null) break true;
                    } else false;
                    if (!occupied) continue;
                    if (seen == pulse) break r;
                    seen += 1;
                } else return error.UnexpectedRydbergPulse;

                for (row, 0..) |maybe_q, i| {
                    const q = maybe_q orelse continue;
                    const partner = fixed[i] orelse continue;
                    const dx = @as(i64, pos[q].x) - pos[partner].x;
                    const dy = @as(i64, pos[q].y) - pos[partner].y;
                    try std.testing.expect(dx * dx + dy * dy <= db * db);
                }
                pulse += 1;
            },
            else => {},
        };
    }

    // Exactly one pulse per occupied timeframe.
    var expected: usize = 0;
    for (moveable) |r| {
        const occupied = for (r) |q| {
            if (q != null) break true;
        } else false;
        if (occupied) expected += 1;
    }
    try std.testing.expectEqual(expected, pulse);
}

test "moveAodCompute pairs each timeframe's qubits within blockade range" {
    const gpa = std.testing.allocator;
    const cfg = testShuttleCfg();

    // GHZ-shaped rounds: q1 entangles with q0 (timeframe 0, column 0),
    // then slides to column 1 to entangle with q2 (timeframe 1). Paired
    // columns sit dr (500nm) apart, within db (1000nm); a wrong-column
    // pairing would be a full 3000nm column separation away.
    var hw = try Hardware.init(gpa, cfg, 3, &.{
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 1 },
        .{ .row = 2, .col = 2 },
    });
    defer hw.deinit();

    const fixed = [_]?usize{ 0, 2 };
    var t0 = [_]?usize{ 1, null };
    var t1 = [_]?usize{ null, 1 };
    var moveable = [_][]?usize{ &t0, &t1 };

    try hw.moveSlmCompute(&fixed);
    try hw.moveAodCompute(&moveable);

    try expectRydbergPairsWithinBlockade(cfg, &hw, &fixed, &moveable);
}

test {
    std.testing.refAllDecls(@This());
}
