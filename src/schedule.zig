const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");

pub const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

pub const Atom = struct {
    gpa: std.mem.Allocator,
    id: u32,
    pos: Point,
    ops: std.ArrayList(Op),

    pub fn deinit(s: *Atom) void {
        s.ops.deinit(s.gpa);
    }

    fn place(gpa: std.mem.Allocator, id: usize, pos: Point) !Atom {
        return .{
            .gpa = gpa,
            .id = @as(u32, @intCast(id)),
            .pos = pos,
            .ops = .empty,
        };
    }

    fn load(s: *Atom, t: u32) !void {
        try s.ops.append(s.gpa, .{ .t = t, .kind = .{
            .load = .{
                .qubit = s.id,
                .position = s.pos,
            },
        } });
    }

    fn move(s: *Atom, dx: i32, dy: i32, t: u32) !void {
        const src = s.pos;
        s.pos.x += dx;
        s.pos.y += dy;
        try s.ops.append(s.gpa, .{ .t = t, .kind = .{
            .move = .{
                .qubit = s.id,
                .src = src,
                .dest = s.pos,
            },
        } });
    }

    fn moveLeft(s: *Atom, d: u32, t: u32) !void {
        try s.move(-@as(i32, @intCast(d)), 0, t);
    }

    fn moveRight(s: *Atom, d: u32, t: u32) !void {
        try s.move(@intCast(d), 0, t);
    }

    fn moveUp(s: *Atom, d: u32, t: u32) !void {
        try s.move(0, -@as(i32, @intCast(d)), t);
    }

    fn moveDown(s: *Atom, d: u32, t: u32) !void {
        try s.move(0, @intCast(d), t);
    }

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

const RamanTarget = struct { qubit: u32, pos: Point };
const Raman = struct { angle: f64, phase: f64, targets: []const RamanTarget };
const Load = struct { qubit: u32, position: Point };
const Store = struct { qubit: u32, position: Point };
const Move = struct { qubit: u32, src: Point, dest: Point };
const Rydberg = struct { zone: Zone };
const Measure = struct { zone: Zone, qubits: []u32 };

const OpKind = union(enum) {
    raman: Raman,
    load: Load,
    move: Move,
    store: Store,
    rydberg: Rydberg,
    measure: Measure,
};

pub const Op = struct {
    t: u32,
    kind: OpKind,
};

pub const Physical = struct {
    gpa: std.mem.Allocator,
    cfg: arch.ArchConfig,
    ops: std.ArrayList(Op) = .empty,
    placement: []Atom = &.{}, // Working position of each qubit (index = qubit id); mutated as atoms move.
    initial: []Point = &.{}, // Starting storage-zone position of each qubit, frozen at placement time.
    t: u32 = 0,

    // Place qubits in storage zone as defined by the
    // upstream Atom Assembly (Atom Rearrangement).
    pub fn init(gpa: std.mem.Allocator, cfg: arch.ArchConfig, num_qubits: usize) !Physical {
        const grid = cfg.storage_zone.grid();
        const num_col = grid.num_col;
        const num_row = grid.num_row;

        // Center half: columns from 25% to 75% of the grid width.
        const col_start = num_col / 4;
        const col_end = num_col - num_col / 4;

        var sites: std.ArrayList(Point) = .empty;
        defer sites.deinit(gpa);

        for (0..num_row) |row| {
            const i = num_row - 1 - row;
            for (col_start..col_end) |j| {
                try sites.append(gpa, Point{
                    .x = grid.x(j),
                    .y = grid.y(i),
                });
            }
        }

        const plc = try gpa.alloc(Atom, num_qubits);
        for (plc, 0..) |*p, i| {
            p.* = try Atom.place(gpa, i, sites.items[i]);
        }

        var physical = Physical{ .gpa = gpa, .cfg = cfg };
        physical.placement = plc;
        physical.initial = try gpa.alloc(Point, physical.placement.len);
        for (physical.placement, physical.initial) |atom, *p| p.* = atom.pos;

        return physical;
    }

    pub fn deinit(s: *Physical) void {
        for (s.ops.items) |op| {
            switch (op.kind) {
                .raman => |r| s.gpa.free(r.targets),
                .measure => |m| s.gpa.free(m.qubits),
                .rydberg, .load, .move, .store => {},
            }
        }
        s.ops.deinit(s.gpa);
        for (s.placement) |*p| p.deinit();
        s.gpa.free(s.placement);
        s.gpa.free(s.initial);
    }

    pub fn moveSlmCompute(s: *Physical, fixed: []const ?usize) !void {
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
            try a.move(grid.x(col) - a.pos.x + d, 0, s.t);
        }
        s.t += 1;

        // Manhattan step 2: move all atoms to the compute zone row.
        const y_dest = grid.y(1);
        for (register.items) |a| {
            try a.move(0, y_dest - a.pos.y, s.t);
        }
        s.t += 1;

        // Manhattan step 3: x correction to target column, then place atom into compute SLM.
        for (register.items) |a| {
            try a.move(-d, 0, s.t);
            try a.ops.append(a.gpa, .{
                .t = s.t,
                .kind = .{
                    .store = .{
                        .qubit = a.id,
                        .position = a.pos,
                    },
                },
            });
        }

        // Flush pickup + compute-zone move ops to the global ops list.
        for (register.items) |a| {
            for (a.ops.items) |o| {
                try s.ops.append(s.gpa, o);
            }
        }
    }

    pub fn moveSlmStorage(s: *Physical, fixed: []const ?usize) !void {
        // Half compute zone site spacing — used as clearance from trap sites.
        const d_c = s.cfg.compute_zone.grid(0).halfSepX();
        const sgrid = s.cfg.storage_zone.grid();
        // Bottom edge of the storage zone (bottom SLM row y, closest to compute).
        const y_storage_bottom = sgrid.bottomRowY();
        const y_corridor = s.cfg.corridorY();

        // Load each atom into the AOD so the horizontal highlight shows during the return trip.
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| {
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .load = .{
                            .qubit = @intCast(q),
                            .position = s.placement[q].pos,
                        },
                    },
                });
            }
        }
        s.t += 1;

        // Step 2: move LEFT by d_c — rigid shift into the inter-column lane.
        // Shifting by exactly d_c places every atom at an x midpoint between compute
        // columns, so they won't cross a trap site x-column when rising in step 3.
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| {
                const src = s.placement[q].pos;
                const dest = Point{ .x = src.x + d_c, .y = src.y };
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .move = .{
                            .qubit = @intCast(q),
                            .src = src,
                            .dest = dest,
                        },
                    },
                });
                s.placement[q].pos = dest;
            }
        }
        s.t += 1;

        // Step 3: move UP to the inter-zone corridor.
        // Atoms travel vertically at inter-column x positions, clearing all compute
        // zone trap rows without crossing any trap site.
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| {
                const src = s.placement[q].pos;
                if (src.y == y_corridor) continue;
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .move = .{
                            .qubit = @intCast(q),
                            .src = src,
                            .dest = .{ .x = src.x, .y = y_corridor },
                        },
                    },
                });
                s.placement[q].pos.y = y_corridor;
            }
        }
        s.t += 1;

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

            const dest_x = sgrid.x(col);
            const src = s.placement[q].pos;

            if (src.x != dest_x) {
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .move = .{
                            .qubit = @intCast(q),
                            .src = src,
                            .dest = .{ .x = dest_x, .y = src.y },
                        },
                    },
                });
                s.placement[q].pos.x = dest_x;
            }
            col += 1;
        }
        s.t += 1;

        // Step 5: drop to the bottom storage row and emit a Store op to mark the atom
        // as back in the SLM (no longer in the AOD).
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| {
                const src = s.placement[q].pos;
                if (src.y != y_storage_bottom) {
                    try s.ops.append(s.gpa, .{
                        .t = s.t,
                        .kind = .{
                            .move = .{
                                .qubit = @intCast(q),
                                .src = src,
                                .dest = .{ .x = src.x, .y = y_storage_bottom },
                            },
                        },
                    });
                    s.placement[q].pos.y = y_storage_bottom;
                }
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .store = .{
                            .qubit = @intCast(q),
                            .position = s.placement[q].pos,
                        },
                    },
                });
            }
        }
        s.t += 1;
    }

    pub fn moveAodStorage(s: *Physical, aod_qubits: [][]?usize) !void {
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
        for (unique.items) |q| {
            try s.ops.append(s.gpa, .{
                .t = s.t,
                .kind = .{
                    .load = .{
                        .qubit = @intCast(q),
                        .position = s.placement[q].pos,
                    },
                },
            });
        }
        s.t += 1;

        const d_c = s.cfg.compute_zone.grid(0).halfSepX();
        const sgrid = s.cfg.storage_zone.grid();
        const y_storage_bottom = sgrid.bottomRowY();
        const y_corridor = s.cfg.corridorY();

        // Step 1: move RIGHT by d_c — shift into inter-column lane.
        for (unique.items) |q| {
            const src = s.placement[q].pos;
            const dest = Point{ .x = src.x + d_c, .y = src.y };
            try s.ops.append(s.gpa, .{
                .t = s.t,
                .kind = .{
                    .move = .{
                        .qubit = @intCast(q),
                        .src = src,
                        .dest = dest,
                    },
                },
            });
            s.placement[q].pos = dest;
        }
        s.t += 1;

        // Step 2: move UP to the inter-zone corridor.
        for (unique.items) |q| {
            const src = s.placement[q].pos;
            if (src.y == y_corridor) continue;
            try s.ops.append(s.gpa, .{
                .t = s.t,
                .kind = .{
                    .move = .{
                        .qubit = @intCast(q),
                        .src = src,
                        .dest = .{
                            .x = src.x,
                            .y = y_corridor,
                        },
                    },
                },
            });
            s.placement[q].pos.y = y_corridor;
        }
        s.t += 1;

        // Step 3: compress — sequential storage columns in left-to-right order,
        // skipping columns already occupied by atoms that stayed in the storage zone.
        var occ = try occupiedStorageX(s.gpa, unique.items, s.placement, y_storage_bottom);
        defer occ.deinit();

        var col: usize = 0;
        for (unique.items) |q| {
            while (occ.contains(sgrid.x(col))) col += 1;

            const dest_x = sgrid.x(col);
            const src = s.placement[q].pos;

            if (src.x != dest_x) {
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .move = .{
                            .qubit = @intCast(q),
                            .src = src,
                            .dest = .{
                                .x = dest_x,
                                .y = src.y,
                            },
                        },
                    },
                });
                s.placement[q].pos.x = dest_x;
            }
            col += 1;
        }
        s.t += 1;

        // Step 4: drop to the bottom storage row and emit a Store op to mark the atom
        // as back in the SLM (no longer in the AOD).
        for (unique.items) |q| {
            const src = s.placement[q].pos;
            if (src.y != y_storage_bottom) {
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .move = .{
                            .qubit = @intCast(q),
                            .src = src,
                            .dest = .{
                                .x = src.x,
                                .y = y_storage_bottom,
                            },
                        },
                    },
                });
                s.placement[q].pos.y = y_storage_bottom;
            }
            try s.ops.append(s.gpa, .{
                .t = s.t,
                .kind = .{
                    .store = .{
                        .qubit = @intCast(q),
                        .position = s.placement[q].pos,
                    },
                },
            });
        }
        s.t += 1;
    }

    pub fn moveAodCompute(s: *Physical, moveable: [][]?usize) !void {
        // Collect all unique qubit IDs across all timeframes.
        var ordered: std.ArrayList(usize) = .empty;
        defer ordered.deinit(s.gpa);

        var seen = std.AutoHashMap(usize, void).init(s.gpa);
        defer seen.deinit();

        for (moveable) |row| {
            for (row) |maybe_q| {
                if (maybe_q) |q| {
                    const gop = try seen.getOrPut(q);
                    if (!gop.found_existing) try ordered.append(s.gpa, q);
                }
            }
        }
        if (ordered.items.len == 0) return;

        // Pick up atoms from storage, traversing without crossing occupied sites.
        var register = try s.pickup(ordered.items);
        defer register.deinit(s.gpa);

        // Manhattan entry into SLM[1] — mirrors moveSlmCompute for SLM[0].
        const grid = s.cfg.compute_zone.grid(1);
        const d = grid.halfSepX();

        // Step 1: move each atom to its column x + d (inter-column offset avoids crossings).
        for (register.items, 0..) |a, i| {
            try a.move(grid.x(i) - a.pos.x + d, 0, s.t);
        }
        s.t += 1;

        // Step 2: drop all atoms to SLM[1] row y.
        const y_dest = grid.y(1);
        for (register.items) |a| {
            try a.move(0, y_dest - a.pos.y, s.t);
        }
        s.t += 1;

        // Step 3: slide left d to land on column x, then place into compute SLM.
        for (register.items) |a| {
            try a.move(-d, 0, s.t);
            try a.ops.append(a.gpa, .{
                .t = s.t,
                .kind = .{
                    .store = .{
                        .qubit = a.id,
                        .position = a.pos,
                    },
                },
            });
        }
        s.t += 1;

        // Flush buffered ops (pickup + compute entry) to global ops list.
        for (register.items) |a| {
            for (a.ops.items) |o| {
                try s.ops.append(s.gpa, o);
            }
        }

        // Sweep: for each timeframe, lift atoms into AOD (t), slide to column (t),
        // then deposit back into SLM (t+1, red flash). Store only fires when atoms moved.
        for (moveable) |row| {
            var moved_q: std.ArrayList(usize) = .empty;
            defer moved_q.deinit(s.gpa);

            for (row, 0..) |maybe_q, i| {
                if (maybe_q) |q| {
                    const dest_x = grid.x(i);
                    const src = s.placement[q].pos;

                    if (src.x == dest_x) continue;

                    try s.ops.append(s.gpa, .{
                        .t = s.t,
                        .kind = .{
                            .load = .{
                                .qubit = @intCast(q),
                                .position = src,
                            },
                        },
                    });

                    try s.ops.append(s.gpa, .{
                        .t = s.t,
                        .kind = .{
                            .move = .{
                                .qubit = @intCast(q),
                                .src = src,
                                .dest = .{
                                    .x = dest_x,
                                    .y = src.y,
                                },
                            },
                        },
                    });

                    s.placement[q].pos.x = dest_x;
                    try moved_q.append(s.gpa, q);
                }
            }
            s.t += 1;

            for (moved_q.items) |q| {
                try s.ops.append(s.gpa, .{
                    .t = s.t,
                    .kind = .{
                        .store = .{
                            .qubit = @intCast(q),
                            .position = s.placement[q].pos,
                        },
                    },
                });
            }
            if (moved_q.items.len > 0) s.t += 1;
        }
    }

    // Apply single-qubit U gates as Raman pulses at the atoms' current
    // storage-zone positions. All gates of the batch fire in one timestep.
    pub fn raman(s: *Physical, u_gates: []const circuit.U) !void {
        if (u_gates.len == 0) return;
        // FIXME, do we need a list of targets?
        for (u_gates) |gate| {
            var targets: std.ArrayList(RamanTarget) = .empty;

            try targets.append(s.gpa, .{
                .qubit = @intCast(gate.qubit),
                .pos = s.placement[gate.qubit].pos,
            });

            try s.ops.append(s.gpa, .{
                .t = s.t,
                .kind = .{
                    .raman = .{
                        .angle = gate.theta,
                        .phase = gate.phi,
                        .targets = try targets.toOwnedSlice(s.gpa),
                    },
                },
            });
        }
        s.t += 1;
    }

    // Pick up atoms from storage in `ord` order, traversing without
    // crossing occupied sites.
    fn pickup(s: *Physical, ord: []const usize) !Register {
        const d = s.cfg.storage_zone.grid().halfSepX();

        var register: Register = .empty;
        errdefer register.deinit(s.gpa);

        if (ord.len == 0) return register;

        // Pick up first atom.
        try pickUpAtom(&register, s.gpa, &s.placement[ord[0]], s.t);
        s.t += 1;
        var front = s.placement[ord[0]];

        // Move the registered atoms to always make the
        // next qubit the front of the row.
        for (ord[1..]) |q| {
            const next = s.placement[q];

            if (next.isLeftOf(front)) {
                const dx: i32 = front.pos.x - next.pos.x;
                for (register.items) |*atom| try atom.*.moveUp(@intCast(d), s.t);
                s.t += 1;
                for (register.items) |*atom| try atom.*.moveLeft(@intCast(dx + d), s.t);
                s.t += 1;
                // Before descending, shift any atom that would land on an occupied site.
                var conflict = true;
                while (conflict) {
                    conflict = false;
                    for (register.items) |*atom| {
                        if (siteOccupied(register, s.placement, atom.*.pos.x, atom.*.pos.y + d)) {
                            try atom.*.moveLeft(@intCast(d), s.t);
                            conflict = true;
                        }
                    }
                    if (conflict) s.t += 1;
                }
                for (register.items) |*atom| try atom.*.moveDown(@intCast(d), s.t);
                s.t += 1;
            }

            try pickUpAtom(&register, s.gpa, &s.placement[q], s.t);
            s.t += 1;
            front = next;
        }

        // Move all loaded atoms down together at the same timestep.
        for (register.items) |*a| {
            try a.*.moveDown(@intCast(4 * d), s.t);
        }
        s.t += 1;

        return register;
    }
};

/// Indexed by qubit id; null means the atom hasn't been picked up.
/// Backed by a single allocation sized to the number of sites.
pub const Register = std.ArrayList(*Atom);

fn pickUpAtom(
    register: *Register,
    gpa: std.mem.Allocator,
    atom: *Atom,
    t: u32,
) !void {
    try atom.load(t);
    try register.append(gpa, atom);
}

// Returns true if an unregistered atom occupies (x, y).
fn siteOccupied(register: Register, placement: []const Atom, x: i32, y: i32) bool {
    outer: for (placement) |atom| {
        if (atom.pos.x != x or atom.pos.y != y) continue;
        for (register.items) |r| {
            if (r.id == atom.id) continue :outer;
        }
        return true;
    }
    return false;
}

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
