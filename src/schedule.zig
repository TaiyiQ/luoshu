const std = @import("std");
const arch = @import("arch");

pub const Zone = enum { storage, compute, readout };

pub const Atom = struct {
    id: u32,
    pos: Point,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Site = struct {
    row: u32,
    col: u32,
};

pub const RamanTarget = struct {
    qubit: u32,
    pos: Point,
};

const Raman = struct {
    angle: f64,
    phase: f64,
    targets: []const RamanTarget,
};

/// One single-qubit rotation request, as handed over by the driver. The
/// pulse implements the equatorial rotation R(angle, phase) =
/// Rz(phase)Ry(angle)Rz(-phase); the driver lowers a front-end
/// U(theta, phi, lambda) into this form via virtual-Z frame tracking,
/// so phase = 0 fires a plain Ry.
pub const RamanGate = struct {
    qubit: u32,

    // Physical Raman pulse.
    angle: f64,

    // Drive phase (phi_drive).
    phase: f64,
};

const Load = struct {
    qubit: u32,
    position: Point,
};

const Store = struct {
    qubit: u32,
    position: Point,
};

pub const Move = struct {
    qubit: u32,
    src: Point,
    dest: Point,
};

const Rydberg = struct {
    zone: Zone,
    /// The routed CZ pairs this pulse is meant to entangle. The verifier
    /// checks each pair sits within the blockade radius at pulse time.
    pairs: []const [2]u32 = &.{},
};

const Measure = struct {
    zone: Zone,
    qubits: []u32,
};

const Reset = struct {
    zone: Zone,
    qubits: []u32,
};

pub const OpKind = union(enum) {
    raman: Raman,
    load: Load,
    move: Move,
    store: Store,
    rydberg: Rydberg,
    measure: Measure,
    reset: Reset,
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

    // Column offset of the current sequence's compute block, chosen by
    // moveSlmCompute so the block lands in the closest storage columns.
    col_offset: usize = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        cfg: arch.ArchConfig,
        num_qubits: usize,
        initial_sites: ?[]const Site,
    ) !Hardware {
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

        var hw = Hardware{
            .gpa = gpa,
            .arena = .init(gpa),
            .cfg = cfg,
        };
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
        try s.emit(.{
            .load = .{
                .qubit = a.id,
                .position = a.pos,
            },
        });
    }

    // Deposit an atom into the SLM at its current position (leaves the AOD).
    fn storeAtom(s: *Hardware, a: *const Atom) !void {
        try s.emit(.{
            .store = .{
                .qubit = a.id,
                .position = a.pos,
            },
        });
    }

    // Displace an atom; its placement position tracks the move.
    fn moveAtom(s: *Hardware, a: *Atom, dx: i32, dy: i32) !void {
        const src = a.pos;
        a.pos.x += dx;
        a.pos.y += dy;
        try s.emit(.{
            .move = .{
                .qubit = a.id,
                .src = src,
                .dest = a.pos,
            },
        });
    }

    pub fn moveSlmCompute(s: *Hardware, fixed: []const ?usize) !void {
        var slots = try occupiedSlots(s.gpa, fixed);
        defer slots.deinit(s.gpa);

        const grid = s.cfg.compute_zone.grid(0);
        s.col_offset = bestColOffset(
            grid,
            fixed.len,
            slots.qubits.items,
            slots.cols.items,
            s.placement,
        );

        var register = try s.pickup(slots.qubits.items);
        defer register.deinit(s.gpa);

        // Manhattan entry into compute SLM[0]'s top row.
        try s.enterComputeSlm(register.items, slots.cols.items, grid, true);
    }

    pub fn moveSlmStorage(s: *Hardware, fixed: []const ?usize) !void {
        var returning: std.ArrayList(usize) = .empty;
        defer returning.deinit(s.gpa);

        for (fixed) |maybe_q| {
            if (maybe_q) |q| try returning.append(s.gpa, q);
        }
        if (returning.items.len == 0) return;

        // Fixed atoms sat stored in the compute SLM; lift them out first.
        for (returning.items) |q| try s.loadAtom(&s.placement[q]);
        s.step();

        try s.returnToStorage(returning.items);
    }

    pub fn moveAodStorage(s: *Hardware, aod_qubits: [][]?usize) !void {
        // Collect all unique qubit IDs across all timeframes.
        const seen = try s.gpa.alloc(bool, s.placement.len);
        defer s.gpa.free(seen);
        @memset(seen, false);

        var unique: std.ArrayList(usize) = .empty;
        defer unique.deinit(s.gpa);

        for (aod_qubits) |row| {
            for (row) |maybe_q| {
                if (maybe_q) |q| {
                    if (!seen[q]) {
                        seen[q] = true;
                        try unique.append(s.gpa, q);
                    }
                }
            }
        }
        if (unique.items.len == 0) return;

        // Sort by current x so sequential column assignments preserve left-to-right order.
        std.sort.block(usize, unique.items, s.placement, struct {
            fn lt(p: []const Atom, a: usize, b: usize) bool {
                return p[a].pos.x < p[b].pos.x;
            }
        }.lt);

        try s.returnToStorage(unique.items);
    }

    // Return trip home for `qubits`, already held in the AOD, in order.
    fn returnToStorage(s: *Hardware, qubits: []const usize) !void {
        // Half compute zone site spacing — used as clearance from trap sites.
        const d_c = s.cfg.compute_zone.grid(0).halfSepX();
        const y_corridor = s.cfg.corridorY();

        // Step 1: move RIGHT by d_c — rigid shift into the inter-column lane.
        // Shifting by exactly d_c places every atom at an x midpoint between compute
        // columns, so they won't cross a trap site x-column when rising in step 2.
        for (qubits) |q| try s.moveAtom(&s.placement[q], d_c, 0);
        s.step();

        // Step 2: move UP to the inter-zone corridor.
        // Atoms travel vertically at inter-column x positions, clearing all compute
        // zone trap rows without crossing any trap site.
        for (qubits) |q| {
            const a = &s.placement[q];
            if (a.pos.y == y_corridor) continue;
            try s.moveAtom(a, 0, y_corridor - a.pos.y);
        }
        s.step();

        // Steps 3-4: compress onto free storage columns and drop home.
        try s.compressToStorage(qubits);
    }

    // Return a register across as few storage rows as possible. Rows with the are
    // filled first and the last batch uses the tightest row that fits it.
    fn compressToStorage(s: *Hardware, qubits: []const usize) !void {
        const sgrid = s.cfg.storage_zone.grid();

        const plan = try planStorageRows(
            s.gpa,
            qubits,
            s.placement,
            sgrid,
        );
        defer s.gpa.free(plan);

        var held: std.ArrayList(usize) = .empty;
        defer held.deinit(s.gpa);
        try held.appendSlice(s.gpa, qubits);

        const d_x = sgrid.halfSepX();
        const d_y = @divTrunc(sgrid.sep_nm[1], 2);

        for (plan, 0..) |batch, batch_i| {
            const row_y = sgrid.y(batch.row);
            var occ = try occupiedStorageX(s.gpa, qubits, s.placement, row_y);
            defer occ.deinit();

            const free_col = try s.gpa.alloc(bool, sgrid.num_col);
            defer s.gpa.free(free_col);
            for (free_col, 0..) |*is_free, col| {
                is_free.* = !occ.contains(sgrid.x(col));
            }

            const lane_x = try s.gpa.alloc(i32, held.items.len);
            defer s.gpa.free(lane_x);
            const store_here = try s.gpa.alloc(bool, held.items.len);
            defer s.gpa.free(store_here);
            @memset(store_here, false);

            // The last batch.
            if (batch.count == held.items.len) {
                var free_x: std.ArrayList(i32) = .empty;
                defer free_x.deinit(s.gpa);
                for (free_col, 0..) |is_free, col| {
                    if (is_free) try free_x.append(s.gpa, sgrid.x(col));
                }

                const xs = try s.gpa.alloc(i32, held.items.len);
                defer s.gpa.free(xs);
                for (held.items, xs) |q, *x| x.* = s.placement[q].pos.x;

                const dest = try assignNearestColumns(s.gpa, xs, free_x.items);
                defer s.gpa.free(dest);
                for (dest, 0..) |x, i| {
                    lane_x[i] = x + d_x;
                    store_here[i] = true;
                }
            }
            // Batch before.
            else {
                var stores_left = batch.count;
                var next_free: usize = 0;
                for (held.items, 0..) |_, i| {
                    var col: ?usize = null;
                    // If all remaining atoms need to be accomodated by this batch.
                    if (stores_left == held.items.len - i) {
                        while (next_free < free_col.len and !free_col[next_free]) {
                            next_free += 1;
                        }
                        col = next_free;
                    }
                    // If not, check the free site with the same index.
                    else if (stores_left > 0 and i < free_col.len and free_col[i]) {
                        col = i;
                    }

                    // If the current atom is to be stored.
                    if (col) |c| {
                        lane_x[i] = sgrid.x(c) + d_x;
                        store_here[i] = true;
                        free_col[c] = false;
                        stores_left -= 1;
                        next_free = @max(next_free, c + 1);
                    }
                    // If the current atom is not to be stored
                    else if (i < sgrid.num_col) {
                        lane_x[i] = sgrid.x(i) + d_x;
                    }
                    // Extra AOD columns extend to the right.
                    else {
                        lane_x[i] = sgrid.x(sgrid.num_col - 1) +
                            @as(i32, @intCast(i - sgrid.num_col + 1)) * sgrid.sep_nm[0] + d_x;
                    }
                }
                // This batch has done.
                std.debug.assert(stores_left == 0);
            }

            // If the complete AOD register fits on the bottom row, use the two-frame fast path.
            if (plan.len == 1 and batch.row == sgrid.num_row - 1) {
                for (held.items, lane_x) |q, x| {
                    const a = &s.placement[q];
                    const dest_x = x - d_x;
                    if (a.pos.x != dest_x) try s.moveAtom(a, dest_x - a.pos.x, 0);
                }
                s.step();

                for (held.items) |q| {
                    const a = &s.placement[q];
                    if (a.pos.y != row_y) try s.moveAtom(a, 0, row_y - a.pos.y);
                    try s.storeAtom(a);
                }
                s.step();

                held.clearRetainingCapacity();
                continue;
            }

            // If not, take a slower path.
            // Align the complete register in a trap-free horizontal band.
            for (held.items, lane_x) |q, x| {
                const a = &s.placement[q];
                if (a.pos.x != x) try s.moveAtom(a, x - a.pos.x, 0);
            }
            s.step();

            // Get the the whole AOD row to the selected storage row through inter-column lanes.
            for (held.items) |q| {
                const a = &s.placement[q];
                if (a.pos.y != row_y) try s.moveAtom(a, 0, row_y - a.pos.y);
            }
            s.step();

            // Store atoms of current batch.
            for (held.items, store_here) |q, do_store| {
                if (!do_store) continue;
                const a = &s.placement[q];
                try s.moveAtom(a, -d_x, 0);
                try s.storeAtom(a);
            }
            s.step();

            var next_held: std.ArrayList(usize) = .empty;
            defer next_held.deinit(s.gpa);
            for (held.items, store_here) |q, did_store| {
                if (!did_store) try next_held.append(s.gpa, q);
            }
            held.clearRetainingCapacity();
            try held.appendSlice(s.gpa, next_held.items);

            // Before changing column assignments for the next row, lift the remaining register into the gap.
            // A horizontal move on the row itself would sweep storage traps.
            if (batch_i + 1 < plan.len) {
                for (held.items) |q| try s.moveAtom(&s.placement[q], 0, -d_y);
                s.step();
            }
        }

        std.debug.assert(held.items.len == 0);
    }

    // Every AOD qubit occupies a slot in every timeframe (active or
    // resting), so the first row fixes both the pickup order and each
    // atom's entry column: atoms are stored directly at their first
    // timeframe positions, and the first sweep iteration degenerates
    // to the Rydberg pulse alone.
    pub fn moveAodCompute(s: *Hardware, fixed: []const ?usize, moveable: [][]?usize) !void {
        if (moveable.len == 0) return;

        var slots = try occupiedSlots(s.gpa, moveable[0]);
        defer slots.deinit(s.gpa);

        if (slots.qubits.items.len == 0) return;

        // Pick up atoms from storage, traversing without crossing occupied sites.
        var register = try s.pickup(slots.qubits.items);
        defer register.deinit(s.gpa);

        // Register stays in the AOD: the sweeps fly it from
        // row to row and the pulses fire on held atoms.
        // Only the return trip puts it back into a trap.
        const grid = s.cfg.compute_zone.grid(1);
        try s.enterComputeSlm(register.items, slots.cols.items, grid, false);

        try s.sweepMoveableRows(moveable, fixed, grid);
    }

    /// Manhattan entry of a freshly picked-up register into a compute SLM:
    /// If `deposit=false` atoms are parked on the sites but stays in the AOD.
    fn enterComputeSlm(
        s: *Hardware,
        register: []const *Atom,
        cols: []const usize,
        grid: arch.Grid,
        deposit: bool,
    ) !void {
        const d = grid.halfSepX();

        // Step 1: move each atom to its target column x + d
        for (register, cols) |a, col| {
            try s.moveAtom(a, grid.x(col + s.col_offset) - a.pos.x + d, 0);
        }
        s.step();

        // Step 2: drop all atoms to the SLM's top row.
        const y_dest = grid.y(0);
        for (register) |a| {
            try s.moveAtom(a, 0, y_dest - a.pos.y);
        }
        s.step();

        // Step 3: slide left d to land on column x.
        for (register) |a| {
            try s.moveAtom(a, -d, 0);
            if (deposit) try s.storeAtom(a);
        }
        s.step();
    }

    /// Sweeps each timeframe row: slides the held register's atoms to this
    /// row's columns, then fires the entangling pulse pairing them with
    /// their fixed SLM[0] partners. The register never leaves the AOD.
    fn sweepMoveableRows(
        s: *Hardware,
        moveable: [][]?usize,
        fixed: []const ?usize,
        grid: arch.Grid,
    ) !void {
        for (moveable) |row| {
            var has_qubit = false;
            for (row, 0..) |maybe_q, i| {
                if (maybe_q) |q| {
                    has_qubit = true;
                    const a = &s.placement[q];
                    const dest_x = grid.x(i + s.col_offset);
                    if (a.pos.x == dest_x) continue;

                    try s.moveAtom(a, dest_x - a.pos.x, 0);
                }
            }
            s.step();

            if (has_qubit) {
                var pairs: std.ArrayList([2]u32) = .empty;
                for (row, 0..) |maybe_q, i| {
                    const q = maybe_q orelse continue;
                    if (i >= fixed.len) continue;
                    const partner = fixed[i] orelse continue;
                    try pairs.append(s.arena.allocator(), .{ @intCast(partner), @intCast(q) });
                }
                try s.emit(.{ .rydberg = .{ .zone = .compute, .pairs = pairs.items } });
                s.step();
            }
        }
    }

    // Apply single-qubit rotations as Raman pulses at the atoms' current
    // storage-zone positions. All gates of the batch fire in one timestep.
    pub fn raman(s: *Hardware, gates: []const RamanGate) !void {
        // Raman.targets is a slice so one op could carry a whole batch, but
        // this is the only producer and it always allocates a 1-element
        // slice, emitting one op per gate instead. Batching into a single
        // multi-target op would change the emitted frame/JSON shape that
        // verify.zig and serialize.zig read, so leave as-is until there's a
        // reason to actually batch.
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

    /// Manhattan entry into the readout zone for a register staged in the
    /// trap-free band below storage, mirroring enterComputeSlm: fan out to
    /// the compute inter-column lanes, descend through the zone to the
    /// hover band just above the readout row, slide to sequential readout
    /// columns there, then drop onto the sites and store. Every horizontal
    /// leg runs in a trap-free band and every vertical leg rides a lane or
    /// lands on its endpoint, so no move sweeps a trap site. `start`
    /// continues the lane/column numbering across trips.
    fn enterReadout(s: *Hardware, qubits: []const usize, start: usize) !void {
        const cgrid = s.cfg.compute_zone.grid(0);
        const d_c = cgrid.halfSepX();
        const rgrid = s.cfg.readout_zone.grid();
        const d_r = rgrid.halfSepX();
        const y_hover = rgrid.y(0) - d_r;

        // Step 1: fan out, one inter-column lane per atom. The register
        // arrives packed left-to-right and lane x rises with the slot
        // index, so no held columns cross.
        for (qubits, start..) |q, i| {
            const a = &s.placement[q];
            const lane_x = cgrid.x(i) + d_c;
            if (a.pos.x != lane_x) try s.moveAtom(a, lane_x - a.pos.x, 0);
        }
        s.step();

        // Step 2: descend through the compute zone to the hover band.
        for (qubits) |q| {
            const a = &s.placement[q];
            if (a.pos.y != y_hover) try s.moveAtom(a, 0, y_hover - a.pos.y);
        }
        s.step();

        // Step 3: slide to sequential readout columns inside the band.
        for (qubits, start..) |q, i| {
            const a = &s.placement[q];
            const dest_x = rgrid.x(i);
            if (a.pos.x != dest_x) try s.moveAtom(a, dest_x - a.pos.x, 0);
        }
        s.step();

        // Step 4: drop onto the readout sites and deposit.
        for (qubits) |q| {
            const a = &s.placement[q];
            try s.moveAtom(a, 0, d_r);
            try s.storeAtom(a);
        }
        s.step();
    }

    // Out leg of the reset round trip: pick the reset set up from storage
    // and park it at sequential readout columns, so the repump light fires
    // far from every coherent atom.
    pub fn moveResetReadout(s: *Hardware, qubits: []const u32) !void {
        const ord = try s.gpa.alloc(usize, qubits.len);
        defer s.gpa.free(ord);

        for (ord, qubits) |*o, q| o.* = q;

        // Bottom (compute-facing) row first, then by x, so pickup advances
        // rightward within each row and the register packs left-to-right.
        std.sort.block(usize, ord, s.placement, struct {
            fn lt(p: []const Atom, a: usize, b: usize) bool {
                if (p[a].pos.y != p[b].pos.y) return p[a].pos.y > p[b].pos.y;
                return p[a].pos.x < p[b].pos.x;
            }
        }.lt);

        // Collect from storage and stage in the trap-free band below it.
        // The register's atoms are placement[ord[i]] in slot order, so the
        // entry works off `ord` directly.
        var register = try s.pickup(ord);
        register.deinit(s.gpa);

        try s.enterReadout(ord, 0);
    }

    // Repump the listed qubits to |0> at their current readout-zone
    // positions. Fires between the two legs of the reset round trip, with
    // every reset atom parked in a readout SLM trap.
    pub fn reset(s: *Hardware, qubits: []const u32) !void {
        try s.emit(.{
            .reset = .{
                .zone = .readout,
                .qubits = try s.arena.allocator().dupe(u32, qubits),
            },
        });
        s.step();
    }

    // Home leg of the reset round trip: lift the freshly repumped atoms
    // off the readout row, ascend through the compute zone's inter-column
    // lanes to the corridor, then compress onto free bottom-row storage
    // columns — the same homecoming gated atoms make after a CZ episode.
    pub fn moveResetStorage(s: *Hardware, qubits: []const u32) !void {
        const ord = try s.gpa.alloc(usize, qubits.len);
        defer s.gpa.free(ord);

        for (ord, qubits) |*o, q| o.* = q;

        // Every reset atom sits on the one readout row; left-to-right
        // order keeps lane and column assignment crossing-free.
        std.sort.block(usize, ord, s.placement, struct {
            fn lt(p: []const Atom, a: usize, b: usize) bool {
                return p[a].pos.x < p[b].pos.x;
            }
        }.lt);

        const cgrid = s.cfg.compute_zone.grid(0);
        const d_c = cgrid.halfSepX();
        const d_r = s.cfg.readout_zone.grid().halfSepX();
        const y_corridor = s.cfg.corridorY();

        for (ord) |q| try s.loadAtom(&s.placement[q]);
        s.step();

        // Step 1: rise off the readout sites into the hover band above the
        // row, so the slide to the lanes sweeps no readout trap site.
        for (ord) |q| try s.moveAtom(&s.placement[q], 0, -d_r);
        s.step();

        // Step 2: slide back onto the inter-column lanes inside the band.
        for (ord, 0..) |q, i| {
            const a = &s.placement[q];
            const lane_x = cgrid.x(i) + d_c;
            if (a.pos.x != lane_x) try s.moveAtom(a, lane_x - a.pos.x, 0);
        }
        s.step();

        // Step 3: ascend to the inter-zone corridor, clearing all compute
        // zone trap rows without crossing any trap site.
        for (ord) |q| {
            const a = &s.placement[q];
            if (a.pos.y == y_corridor) continue;
            try s.moveAtom(a, 0, y_corridor - a.pos.y);
        }
        s.step();

        // Steps 4-5: compress onto free storage columns and drop home.
        try s.compressToStorage(ord);
    }

    // Shuttle every atom from the storage zone to the readout zone: shift
    // into the storage gap midpoints, descend to the trap-free staging
    // band, then enter the readout zone via the compute lanes.
    //
    // Gated atoms come home to the bottom storage row, but idle atoms
    // still sit wherever assembly delivered them, possibly on several
    // rows — and the AOD drives a single row tone, so the register makes
    // one trip per occupied storage row, nearest the compute zone first.
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

        const sgrid = s.cfg.storage_zone.grid();
        const d_s = sgrid.halfSepX();
        // The same trap-free band pickup stages its register in.
        const y_stage = sgrid.bottomRowY() + 4 * d_s;

        var start: usize = 0;
        while (start < order.len) {
            const row_y = s.placement[order[start]].pos.y;
            var end = start;
            while (end < order.len and s.placement[order[end]].pos.y == row_y) end += 1;
            const trip = order[start..end];

            for (trip) |q| try s.loadAtom(&s.placement[q]);
            s.step();

            // Step 1: move RIGHT by d_s — rigid shift into the storage gap
            // midpoints, half a pitch from every trap column, so the
            // descent crosses no trap site whatever rows it passes.
            for (trip) |q| try s.moveAtom(&s.placement[q], d_s, 0);
            s.step();

            // Step 2: descend to the staging band below the storage zone.
            for (trip) |q| {
                const a = &s.placement[q];
                if (a.pos.y != y_stage) try s.moveAtom(a, 0, y_stage - a.pos.y);
            }
            s.step();

            // Steps 3-6: lanes, descent, hover slide, drop. Lane and
            // column indices continue across trips, so every trip parks
            // right of the atoms already deposited.
            try s.enterReadout(trip, start);

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

    // Pick up atoms from storage in order, traversing without crossing occupied sites.
    // The physical AOD drives a single row tone, so the register holds one shared
    // y at every instant; only the column tones move per-atom.
    fn pickup(s: *Hardware, ord: []const usize) !Register {
        // Every picked-up atom occupies its own AOD column.
        if (ord.len > s.cfg.aod.max_num_col) return error.AodCapacityExceeded;

        const sgrid = s.cfg.storage_zone.grid();
        const d = sgrid.halfSepX();

        var register: Register = .empty;
        errdefer register.deinit(s.gpa);

        if (ord.len == 0) return register;

        // Loads accumulate in one frame until the register must move:
        // A run of same-row rightward pickups is a single parallel load phase.
        try s.loadAtom(&s.placement[ord[0]]);
        try register.append(s.gpa, &s.placement[ord[0]]);

        var front = s.placement[ord[0]].pos;

        for (ord[1..]) |q| {
            const next = s.placement[q].pos;

            // Advancing rightward along the row needs no traversal:
            // The register always parks left of the last pickup,
            // so the atom loads in the order required in the compute zone.
            if (next.y != front.y or next.x < front.x) {
                s.step();

                for (register.items) |a| try s.moveAtom(a, 0, -d);
                s.step();

                try s.packRegister(&register, next.x);

                for (register.items) |a| try s.moveAtom(a, 0, next.y - a.pos.y);
                s.step();
            }

            try s.loadAtom(&s.placement[q]);
            try register.append(s.gpa, &s.placement[q]);

            front = next;
        }
        s.step();

        // Stage the register in the trap-free band past the bottom storage
        // row. From the bottom row that is a plain drop; from any other row
        // the descent crosses trap rows, so hover and pack first.
        const y_stage = sgrid.bottomRowY() + 4 * d;
        if (front.y != sgrid.bottomRowY()) {
            for (register.items) |a| try s.moveAtom(a, 0, -d);
            s.step();
            try s.packRegister(&register, front.x);
        }

        for (register.items) |a| try s.moveAtom(a, 0, y_stage - a.pos.y);
        s.step();

        return register;
    }

    // Packs the register's columns one per inter-column gap immediately
    // left of `anchor_x`, parked at the gap midpoints: a following dip or
    // vertical ride then crosses no trap site, whatever rows it passes,
    // and no held column ever comes closer than half a pitch to a stored atom.
    fn packRegister(s: *Hardware, register: *const Register, anchor_x: i32) !void {
        const sgrid = s.cfg.storage_zone.grid();
        const d = sgrid.halfSepX();

        for (register.items, 0..) |a, i| {
            const back: i32 = @intCast(register.items.len - 1 - i);
            const dest_x = anchor_x - d - back * sgrid.sep_nm[0];
            if (a.pos.x != dest_x) try s.moveAtom(a, dest_x - a.pos.x, 0);
        }
        s.step();
    }
};

/// Atoms currently held by the AOD, in pickup order (one AOD column each),
/// pointing into Hardware.placement so moves track automatically.
pub const Register = std.ArrayList(*Atom);

/// A timeframe row's occupied slots: qubit ids
/// and their column indices, in slot order.
const Slots = struct {
    qubits: std.ArrayList(usize) = .empty,
    cols: std.ArrayList(usize) = .empty,

    fn deinit(sl: *Slots, gpa: std.mem.Allocator) void {
        sl.qubits.deinit(gpa);
        sl.cols.deinit(gpa);
    }
};

fn occupiedSlots(gpa: std.mem.Allocator, row: []const ?usize) !Slots {
    var slots = Slots{};
    errdefer slots.deinit(gpa);

    for (row, 0..) |maybe_q, col| {
        if (maybe_q) |q| {
            try slots.qubits.append(gpa, q);
            try slots.cols.append(gpa, col);
        }
    }

    return slots;
}

// Returns a set of x coordinates at `y_target` occupied by atoms whose placement
// index is NOT in `returning`. Caller must deinit the returned map.
fn occupiedStorageX(
    gpa: std.mem.Allocator,
    returning: []const usize,
    placement: []const Atom,
    y_target: i32,
) !std.AutoHashMap(i32, void) {
    const ret_set = try gpa.alloc(bool, placement.len);
    defer gpa.free(ret_set);
    @memset(ret_set, false);

    for (returning) |q| ret_set[q] = true;

    var occ = std.AutoHashMap(i32, void).init(gpa);
    errdefer occ.deinit();

    for (placement, 0..) |atom, i| {
        if (ret_set[i]) continue;
        if (atom.pos.y == y_target) try occ.put(atom.pos.x, {});
    }

    return occ;
}

// At a given row, how many atoms are to be stored.
const StorageBatch = struct {
    row: usize,
    count: usize,
};

// At a given row, how many SLM sites are still free.
const StorageCandidate = struct {
    row: usize,
    free: usize,
};

// Consume the roomiest rows until one row can hold everything left,
// then choose the tightest such fit.
// The returned batches are ordered bottom-to-top for safe physical traversal.
fn planStorageRows(
    gpa: std.mem.Allocator,
    returning: []const usize,
    placement: []const Atom,
    grid: arch.Grid,
) ![]StorageBatch {
    var candidates: std.ArrayList(StorageCandidate) = .empty;
    defer candidates.deinit(gpa);

    // Count free sites for each storage row.
    for (0..grid.num_row) |row| {
        const row_y = grid.y(row);
        var occupied = try occupiedStorageX(gpa, returning, placement, row_y);
        defer occupied.deinit();

        var free_count: usize = 0;
        for (0..grid.num_col) |col| {
            if (!occupied.contains(grid.x(col))) free_count += 1;
        }
        try candidates.append(gpa, .{ .row = row, .free = free_count });
    }

    // Sort, so that rows with more free sites come first.
    // For rows with equal free sites, lower ones are prioritized.
    std.sort.block(StorageCandidate, candidates.items, {}, struct {
        fn lt(_: void, a: StorageCandidate, b: StorageCandidate) bool {
            if (a.free != b.free) return a.free > b.free;
            return a.row > b.row;
        }
    }.lt);

    var batches: std.ArrayList(StorageBatch) = .empty;
    errdefer batches.deinit(gpa);

    var needed = returning.len;
    var first_unconsumed: usize = 0;
    while (needed > 0) {
        var best_fit: ?usize = null;
        for (candidates.items[first_unconsumed..], first_unconsumed..) |candidate, i| {
            if (candidate.free < needed) continue;
            if (best_fit == null or candidate.free < candidates.items[best_fit.?].free) {
                best_fit = i;
            }
        }

        // If there is a row fitting all remaining atoms,
        // look at the "best fit" row.
        if (best_fit) |i| {
            try batches.append(gpa, .{ .row = candidates.items[i].row, .count = needed });
            needed = 0;
            break;
        }

        // Otherwise, no row has enough sites to fit all remaining atoms.
        // If running out of free sites, throw an error.
        if (first_unconsumed == candidates.items.len or
            candidates.items[first_unconsumed].free == 0)
        {
            return error.StorageRowFull;
        }

        // Accomodate remaining atoms at current row as many as possible.
        const candidate = candidates.items[first_unconsumed];
        try batches.append(gpa, .{ .row = candidate.row, .count = candidate.free });
        needed -= candidate.free;
        first_unconsumed += 1;
    }

    // Sort, so that stores at lower SLM rows are performed earlier.
    std.sort.block(StorageBatch, batches.items, {}, struct {
        fn lt(_: void, a: StorageBatch, b: StorageBatch) bool {
            return a.row > b.row;
        }
    }.lt);

    return batches.toOwnedSlice(gpa);
}

test "planStorageRows fills the roomiest row then uses the best fit" {
    const gpa = std.testing.allocator;
    const grid = arch.Grid{
        .origin_nm = .{ 0, 0 },
        .sep_nm = .{ 1000, 1000 },
        .num_row = 4,
        .num_col = 6,
    };

    // Eight returning atoms sit outside storage. Stored blockers leave
    // [1, 3, 6, 2] free sites in rows 0..3, respectively.
    var placement: std.ArrayList(Atom) = .empty;
    defer placement.deinit(gpa);
    var returning: [8]usize = undefined;
    for (&returning, 0..) |*q, i| {
        q.* = i;
        try placement.append(gpa, .{
            .id = @intCast(i),
            .pos = .{ .x = @intCast(i * 1000), .y = 10_000 },
        });
    }

    const occupied = [_]usize{ 5, 3, 0, 4 };
    for (occupied, 0..) |count, row| {
        for (0..count) |col| {
            try placement.append(gpa, .{
                .id = @intCast(placement.items.len),
                .pos = .{ .x = grid.x(col), .y = grid.y(row) },
            });
        }
    }

    const plan = try planStorageRows(gpa, &returning, placement.items, grid);
    defer gpa.free(plan);

    // Selection is row 2 (six), then the exact-fit row 3 (two). Physical
    // execution is reversed so the AOD register travels bottom-to-top.
    try std.testing.expectEqualSlices(StorageBatch, &.{
        .{ .row = 3, .count = 2 },
        .{ .row = 2, .count = 6 },
    }, plan);
}

// Can every atom take an unused free column within `bound`?
// Two-pointer technique.
fn fitsWithin(xs: []const i32, free: []const i32, bound: i32, dest: ?[]i32) bool {

    // Free site pointer (j):
    // Index of the first free column not yet taken.
    var j: usize = 0;

    // Atom pointer (i):
    // Visit each atom left to right; i is its site in dest.
    for (xs, 0..) |x, i| {

        // Columns too far left can't serve this atom or any later one.
        while (j < free.len and x - free[j] > bound) j += 1;

        // The first surviving column must be within reach to the right.
        if (j == free.len or free[j] - x > bound) return false;

        // Site found.
        if (dest) |d| d[i] = free[j];

        // Site consumed: next atom starts looking one to the right.
        j += 1;
    }

    return true;
}

// Assignment of x-sorted atoms onto sorted free column
// positions, minimizing the worst displacement.
// Binary-search finds the optimal bound and the same
// greedy sweep that checks it builds the witness.
fn assignNearestColumns(
    gpa: std.mem.Allocator,
    xs: []const i32,
    free: []const i32,
) ![]i32 {
    const dest = try gpa.alloc(i32, xs.len);
    errdefer gpa.free(dest);

    if (xs.len == 0) return dest;

    // Corner distances defines the upper bound.
    var lo: i32 = 0;
    var hi: i32 = @intCast(@max(
        @abs(xs[0] - free[free.len - 1]),
        @abs(xs[xs.len - 1] - free[0]),
    ));

    while (lo < hi) {
        const mid = lo + @divTrunc(hi - lo, 2);
        if (fitsWithin(xs, free, mid, null)) hi = mid else lo = mid + 1;
    }

    const ok = fitsWithin(xs, free, lo, dest);
    std.debug.assert(ok);

    return dest;
}

test "assignNearestColumns keeps right-side atoms on the right" {
    const gpa = std.testing.allocator;

    const dest = try assignNearestColumns(
        gpa,
        &.{ 60_000, 71_000 },
        &.{ 0, 1000, 60_000, 62_000, 70_000 },
    );
    defer gpa.free(dest);

    try std.testing.expectEqualSlices(i32, &.{ 60_000, 70_000 }, dest);
}

test "assignNearestColumns trades one atom's slack for the worst case" {
    const gpa = std.testing.allocator;

    // Nearest-per-atom would give atom 0 the column at 9 and push atom 1
    // to 30 (worst 20); the minimax split is 8 -> 0, 10 -> 9 (worst 8).
    const dest = try assignNearestColumns(
        gpa,
        &.{ 8, 10 },
        &.{ 0, 9, 30 },
    );
    defer gpa.free(dest);

    try std.testing.expectEqualSlices(i32, &.{ 0, 9 }, dest);
}

test "assignNearestColumns fills an exact fit across an occupied gap" {
    const gpa = std.testing.allocator;

    // Atom 3000 sits on a free column but must
    // cede it to atom 2000 and shift right.
    const dest = try assignNearestColumns(
        gpa,
        &.{ 1000, 2000, 3000 },
        &.{ 1000, 3000, 4000 },
    );
    defer gpa.free(dest);

    try std.testing.expectEqualSlices(i32, &.{ 1000, 3000, 4000 }, dest);
}

// Column offset that lands a fetched compute block closest to picker up atoms:
// Scans every legal shift of the n-slots-wide block and keeps the one minimizing
// the worst horizontal rearrangment.
fn bestColOffset(
    grid: arch.Grid,
    n_slots: usize,
    qubits: []const usize,
    cols: []const usize,
    placement: []const Atom,
) usize {
    if (qubits.len == 0 or n_slots >= grid.num_col) return 0;

    const d = grid.halfSepX();

    // Closest column to move the atom from storage to compute.
    var best: usize = 0;

    // Minimal x-direction (cost) to move atom.
    var best_cost: i64 = std.math.maxInt(i64);

    for (0..grid.num_col - n_slots + 1) |c| {
        var cost: i64 = 0;

        for (qubits, cols) |q, col| {
            const dx: i64 = @abs(grid.x(col + c) + d - placement[q].pos.x);
            if (dx > cost) cost = dx;
        }

        // If a "closer" column if found, update
        // the best column and cost values.
        if (cost < best_cost) {
            best_cost = cost;
            best = c;
        }
    }

    return best;
}

test "bestColOffset lands the block above its atoms" {
    const grid = arch.Grid{
        .origin_nm = .{ 0, 0 },
        .sep_nm = .{ 1000, 1000 },
        .num_row = 1,
        .num_col = 10,
    };

    // Both atoms park near columns 5-6; packing at column 0 would walk
    // them ~5 pitches left.
    const placement = [_]Atom{
        .{ .id = 0, .pos = .{ .x = 5200, .y = 0 } },
        .{ .id = 1, .pos = .{ .x = 6200, .y = 0 } },
    };
    const off = bestColOffset(grid, 2, &.{ 0, 1 }, &.{ 0, 1 }, &placement);
    try std.testing.expectEqual(5, off);
}

test "bestColOffset minimizes the worst atom's walk" {
    const grid = arch.Grid{
        .origin_nm = .{ 0, 0 },
        .sep_nm = .{ 1000, 1000 },
        .num_row = 1,
        .num_col = 10,
    };

    // The atoms pull in opposite directions: the summed walk ties at
    // 4400 for every offset 3-7, so only the worst-case cost singles
    // out 5, where the longer walk bottoms out at 2400.
    const placement = [_]Atom{
        .{ .id = 0, .pos = .{ .x = 3500, .y = 0 } },
        .{ .id = 1, .pos = .{ .x = 8900, .y = 0 } },
    };
    const off = bestColOffset(grid, 2, &.{ 0, 1 }, &.{ 0, 1 }, &placement);
    try std.testing.expectEqual(@as(usize, 5), off);
}

test "bestColOffset clamps the block to the grid" {
    const grid = arch.Grid{
        .origin_nm = .{ 0, 0 },
        .sep_nm = .{ 1000, 1000 },
        .num_row = 1,
        .num_col = 10,
    };

    // A 9-slot block can only shift by one column, however far right
    // the atom sits.
    const placement = [_]Atom{
        .{ .id = 0, .pos = .{ .x = 20_000, .y = 0 } },
    };
    const off = bestColOffset(grid, 9, &.{0}, &.{0}, &placement);
    try std.testing.expectEqual(1, off);
}

test "init rejects more qubits than loading-window sites" {
    var cfg = arch.testConfig();
    cfg.aod.max_num_row = 1;
    cfg.storage_zone.slm.num_row = 1;
    cfg.readout_zone.slm.num_row = 1;
    cfg.compute_zone.slms = &arch.test_no_slms;

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

    try std.testing.expectEqual(
        Point{ .x = 0, .y = 0 },
        hw.initial[0],
    );
    try std.testing.expectEqual(
        Point{ .x = 1000, .y = 0 },
        hw.initial[1],
    );
    try std.testing.expectEqual(
        Point{ .x = 3000, .y = 0 },
        hw.initial[2],
    );

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
    .{
        .slm_id = 1,
        .num_row = 2,
        .num_col = 4,
        .sep_nm = .{ 3000, 2000 },
        .offset_nm = .{ 0, 0 },
    },
    .{
        .slm_id = 2,
        .num_row = 2,
        .num_col = 4,
        .sep_nm = .{ 3000, 2000 },
        .offset_nm = .{ 0, 500 },
    },
};

// Small three-zone config for shuttling tests: 3x4 storage grid, two
// compute SLMs, one readout row, roomier separations than the baseline.
fn testShuttleCfg() arch.ArchConfig {
    var cfg = arch.testConfig();
    cfg.aod = .{ .aod_id = 0, .min_sep_nm = 500, .max_num_row = 1, .max_num_col = 8 };
    cfg.storage_zone.slm.num_row = 3;
    cfg.compute_zone.offset_nm = .{ 0, 6000 };
    cfg.compute_zone.dr_nm = 500;
    cfg.compute_zone.dw_nm = 2500;
    cfg.compute_zone.slms = &test_compute_slms;
    cfg.readout_zone.offset_nm = .{ 0, 12000 };
    cfg.readout_zone.slm = .{
        .slm_id = 3,
        .num_row = 1,
        .num_col = 4,
        .sep_nm = .{ 1000, 1000 },
        .offset_nm = .{ 0, 0 },
    };
    cfg.constraints.db_nm = 1000;
    cfg.constraints.dz_nm = 1000;
    return cfg;
}

test "moveSlmStorage scans upward for a row that fits the returning register" {
    const gpa = std.testing.allocator;
    const cfg = testShuttleCfg();

    var hw = try Hardware.init(gpa, cfg, 5, &.{
        .{ .row = 2, .col = 0 }, // q0: returning
        .{ .row = 2, .col = 1 }, // q1: returning
        .{ .row = 1, .col = 0 }, // q2: returning
        .{ .row = 2, .col = 2 }, // q3: remains in storage
        .{ .row = 2, .col = 3 }, // q4: remains in storage
    });
    defer hw.deinit();

    const fixed = [_]?usize{ 0, 1, 2 };

    try hw.moveSlmCompute(&fixed);

    try hw.moveSlmStorage(&fixed);

    const storage = cfg.storage_zone.grid();
    const expected_y = storage.y(1);

    try std.testing.expectEqual(expected_y, hw.placement[0].pos.y);
    try std.testing.expectEqual(expected_y, hw.placement[1].pos.y);
    try std.testing.expectEqual(expected_y, hw.placement[2].pos.y);

    try std.testing.expectEqual(hw.initial[3], hw.placement[3].pos);
    try std.testing.expectEqual(hw.initial[4], hw.placement[4].pos);
}

test "moveSlmStorage splits a register across the minimum number of rows" {
    const gpa = std.testing.allocator;

    var wide_compute_slms = test_compute_slms;
    wide_compute_slms[0].num_col = 8;
    wide_compute_slms[1].num_col = 8;
    var cfg = testShuttleCfg();
    cfg.storage_zone.slm.num_row = 4;
    cfg.storage_zone.slm.num_col = 6;
    cfg.compute_zone.offset_nm[1] = 8000;
    cfg.readout_zone.offset_nm[1] = 14_000;
    cfg.compute_zone.slms = &wide_compute_slms;

    // Once q0..q7 leave storage, rows 0..3 have [1, 3, 6, 3] free
    // sites. The planner fills the six-site row and stores the remaining
    // two atoms in the bottom row, rather than making four bottom-up trips.
    // That bottom row deliberately has one spare site, exercising a partial
    // best-fit batch before the full row is visited.
    var hw = try Hardware.init(gpa, cfg, 19, &.{
        .{ .row = 3, .col = 4 }, // q0..q7 return
        .{ .row = 3, .col = 5 },
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 1 },
        .{ .row = 2, .col = 2 },
        .{ .row = 2, .col = 3 },
        .{ .row = 1, .col = 3 },
        .{ .row = 1, .col = 4 },
        .{ .row = 0, .col = 0 }, // q8..q18 remain in storage
        .{ .row = 0, .col = 1 },
        .{ .row = 0, .col = 2 },
        .{ .row = 0, .col = 3 },
        .{ .row = 0, .col = 4 },
        .{ .row = 1, .col = 0 },
        .{ .row = 1, .col = 1 },
        .{ .row = 1, .col = 2 },
        .{ .row = 3, .col = 0 },
        .{ .row = 3, .col = 1 },
        .{ .row = 3, .col = 2 },
    });
    defer hw.deinit();

    const fixed = [_]?usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try hw.moveSlmCompute(&fixed);
    try hw.moveSlmStorage(&fixed);

    const storage = cfg.storage_zone.grid();
    var on_bottom: usize = 0;
    var on_row_two: usize = 0;
    for (hw.placement[0..8]) |atom| {
        if (atom.pos.y == storage.bottomRowY()) on_bottom += 1;
        if (atom.pos.y == storage.y(2)) on_row_two += 1;
    }
    try std.testing.expectEqual(2, on_bottom);
    try std.testing.expectEqual(6, on_row_two);
    for (hw.placement[8..], hw.initial[8..]) |atom, initial| {
        try std.testing.expectEqual(initial, atom.pos);
    }

    var in_aod = try expectSingleAodRow(gpa, hw.frames.items);
    defer in_aod.deinit();
    try std.testing.expectEqual(0, in_aod.count());
}

// Replays `frames`, asserting that all AOD-held atoms share one y at the
// end of every frame, and that every load is inline with the held columns
// at the instant it fires — the trap must form on the atom, and the held
// columns ride the same single row tone, so a register hovering on
// another row cannot load. Returns the held set so callers can also
// assert on the terminal state.
fn expectSingleAodRow(gpa: std.mem.Allocator, frames: []const Frame) !std.AutoHashMap(u32, i32) {
    var in_aod = std.AutoHashMap(u32, i32).init(gpa);
    errdefer in_aod.deinit();

    for (frames) |frame| {
        for (frame.items) |op| switch (op) {
            .load => |l| {
                var held = in_aod.valueIterator();
                while (held.next()) |y| try std.testing.expectEqual(l.position.y, y.*);
                try in_aod.put(l.qubit, l.position.y);
            },
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

test "pickup traversal past an occupied site preserves site exclusivity" {
    const gpa = std.testing.allocator;

    // Widen storage to six columns: three left traversals need the room.
    var cfg = testShuttleCfg();
    cfg.storage_zone.slm.num_col = 6;

    // Bottom row: a blocker at column 0 that is never picked up, and four
    // pickups right to left. The traversal to column 1 packs the register
    // at x -1500, -500, 500, bracketing the blocker at x 0.
    var hw = try Hardware.init(gpa, cfg, 5, &.{
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 5 },
        .{ .row = 2, .col = 4 },
        .{ .row = 2, .col = 3 },
        .{ .row = 2, .col = 1 },
    });
    defer hw.deinit();

    var register = try hw.pickup(&.{ 1, 2, 3, 4 });
    defer register.deinit(gpa);

    // Site exclusivity at the end of every frame.
    const pos = try gpa.dupe(Point, hw.initial);
    defer gpa.free(pos);

    for (hw.frames.items) |frame| {
        for (frame.items) |op| switch (op) {
            .move => |m| pos[m.qubit] = m.dest,
            else => {},
        };
        for (pos[0 .. pos.len - 1], 0..) |p, i| {
            for (pos[i + 1 ..]) |q| {
                try std.testing.expect(p.x != q.x or p.y != q.y);
            }
        }
    }
}

// Held columns pack against each pickup, one column per inter-column gap,
// parked at the gap midpoints. The packing sweeps the register leftward
// past skipped storage sites. No move may cross an atom that is stored
// for the whole frame, and no gap ever holds more than one register atom.
test "pickup packs one register column per storage gap" {
    const gpa = std.testing.allocator;

    var cfg = testShuttleCfg();
    cfg.storage_zone.slm.num_col = 6;

    // Bottom row: pickups at columns 5, 2, 0 advance leftward past
    // stored blockers at columns 1 and 3 that are never picked up.
    var hw = try Hardware.init(gpa, cfg, 5, &.{
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 2 },
        .{ .row = 2, .col = 5 },
        .{ .row = 2, .col = 1 },
        .{ .row = 2, .col = 3 },
    });
    defer hw.deinit();

    var register = try hw.pickup(&.{ 2, 1, 0 });
    defer register.deinit(gpa);

    // Replay with trap tracking: a move may not sweep through an atom
    // that is stored for the whole frame (frame ops are parallel), and
    // positions stay exclusive at the end of every frame.
    const pos = try gpa.dupe(Point, hw.initial);
    defer gpa.free(pos);

    var in_aod = [_]bool{false} ** 5;

    for (hw.frames.items) |frame| {
        const start_aod = in_aod;

        var moves: std.ArrayList([2]Point) = .empty;
        defer moves.deinit(gpa);

        for (frame.items) |op| switch (op) {
            .load => |l| in_aod[l.qubit] = true,
            .store => |st| in_aod[st.qubit] = false,
            .move => |m| {
                try moves.append(gpa, .{ m.src, m.dest });
                pos[m.qubit] = m.dest;
            },
            else => {},
        };

        for (moves.items) |mv| {
            for (pos, 0..) |blocker, q| {
                if (start_aod[q] or in_aod[q]) continue;
                if (mv[0].y == mv[1].y) {
                    try std.testing.expect(blocker.y != mv[0].y or
                        blocker.x <= @min(mv[0].x, mv[1].x) or
                        blocker.x >= @max(mv[0].x, mv[1].x));
                } else {
                    try std.testing.expect(blocker.x != mv[0].x or
                        blocker.y <= @min(mv[0].y, mv[1].y) or
                        blocker.y >= @max(mv[0].y, mv[1].y));
                }
            }
        }

        for (pos[0 .. pos.len - 1], 0..) |a, i| {
            for (pos[i + 1 ..]) |b| {
                try std.testing.expect(a.x != b.x or a.y != b.y);
            }
        }

        // A held column sits either on the column of the site it was just
        // lifted from or at a gap midpoint. With site exclusivity that
        // means at most one register atom between any two adjacent trap
        // columns, half a pitch from both.
        const sgrid = cfg.storage_zone.grid();
        for (pos, 0..) |a, q| {
            if (!in_aod[q]) continue;
            const rel = @mod(a.x - sgrid.x(0), sgrid.sep_nm[0]);
            try std.testing.expect(rel == 0 or rel == sgrid.halfSepX());
        }
    }

    // Staged register: the packed atoms sit one full pitch apart, and the
    // most recently picked atom - never repacked, since staging from the
    // bottom row needs no traversal - is still at its real trap column,
    // half a pitch from the packed atom beside it.
    const sgrid = cfg.storage_zone.grid();
    const sep = sgrid.sep_nm[0];
    const d = sgrid.halfSepX();
    const last = register.items.len - 1;
    for (register.items[1..last], register.items[0 .. last - 1]) |right, left| {
        try std.testing.expectEqual(sep, right.pos.x - left.pos.x);
    }
    try std.testing.expectEqual(d, register.items[last].pos.x - register.items[last - 1].pos.x);
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

// A mid-circuit reset round trip: a subset shuttles from two different
// storage rows to the readout zone, repumps, and comes home — single row
// tone throughout, nobody left in the AOD, reset atoms back on the bottom
// storage row, bystanders untouched.
test "reset round trip keeps a single AOD row and returns the subset home" {
    const gpa = std.testing.allocator;

    var hw = try Hardware.init(gpa, testShuttleCfg(), 4, &.{
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 2 },
        .{ .row = 0, .col = 1 },
        .{ .row = 0, .col = 3 },
    });
    defer hw.deinit();

    try hw.moveResetReadout(&.{ 0, 2 });

    // Both reset atoms parked in the readout zone for the repump.
    const y_readout = hw.cfg.readout_zone.grid().y(0);
    try std.testing.expectEqual(y_readout, hw.placement[0].pos.y);
    try std.testing.expectEqual(y_readout, hw.placement[2].pos.y);

    try hw.reset(&.{ 0, 2 });
    try hw.moveResetStorage(&.{ 0, 2 });

    var in_aod = try expectSingleAodRow(gpa, hw.frames.items);
    defer in_aod.deinit();
    try std.testing.expectEqual(0, in_aod.count());

    // Home on the bottom storage row; bystanders never moved.
    const y_bottom = hw.cfg.storage_zone.grid().bottomRowY();
    try std.testing.expectEqual(y_bottom, hw.placement[0].pos.y);
    try std.testing.expectEqual(y_bottom, hw.placement[2].pos.y);
    try std.testing.expectEqual(hw.initial[1], hw.placement[1].pos);
    try std.testing.expectEqual(hw.initial[3], hw.placement[3].pos);
}

test "sweeps fly the held register between pulses without trap transfers" {
    const gpa = std.testing.allocator;
    const cfg = testShuttleCfg();

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
    try hw.moveAodCompute(&fixed, &moveable);

    var first_pulse: ?usize = null;
    var last_pulse: usize = 0;
    for (hw.frames.items, 0..) |frame, t| {
        for (frame.items) |op| switch (op) {
            .rydberg => {
                if (first_pulse == null) first_pulse = t;
                last_pulse = t;
            },
            else => {},
        };
    }
    try std.testing.expect(first_pulse != null);
    try std.testing.expect(last_pulse > first_pulse.?);

    for (hw.frames.items[first_pulse.?..last_pulse]) |frame| {
        for (frame.items) |op| switch (op) {
            .load, .store => return error.TransferBetweenPulses,
            else => {},
        };
    }
}

// Full driver-shaped schedule for the allocation-failure checks.
fn buildFullSchedule(gpa: std.mem.Allocator) !void {
    var cfg = testShuttleCfg();
    cfg.storage_zone.slm.num_col = 16;

    var hw = try Hardware.init(gpa, cfg, 12, &.{
        .{ .row = 2, .col = 0 },
        .{ .row = 2, .col = 1 },
        .{ .row = 2, .col = 2 },
        .{ .row = 2, .col = 3 },
        .{ .row = 2, .col = 4 },
        .{ .row = 2, .col = 5 },
        .{ .row = 2, .col = 6 },
        .{ .row = 2, .col = 7 },
        .{ .row = 2, .col = 8 },
        .{ .row = 2, .col = 9 },
        .{ .row = 2, .col = 10 },
        .{ .row = 2, .col = 11 },
    });
    defer hw.deinit();

    const fixed = [_]?usize{ 0, 2 };
    var t0 = [_]?usize{ 1, null };
    var t1 = [_]?usize{ null, 1 };
    var moveable = [_][]?usize{ &t0, &t1 };

    try hw.moveSlmCompute(&fixed);
    try hw.moveAodCompute(&fixed, &moveable);
    try hw.moveAodStorage(&moveable);
    try hw.moveSlmStorage(&fixed);
    try hw.raman(&.{.{ .qubit = 1, .angle = 1.0, .phase = 0.0 }});
    try hw.moveResetReadout(&.{1});
    try hw.reset(&.{1});
    try hw.moveResetStorage(&.{1});
    try hw.moveReadout();
    try hw.measure(.readout);
}

test "schedule construction frees scratch on every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildFullSchedule,
        .{},
    );
}

test {
    std.testing.refAllDecls(@This());
}
