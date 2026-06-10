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
    ops: std.ArrayList(Op) = .empty,
    placement: []Atom = &.{}, // Working position of each qubit (index = qubit id); mutated as atoms move.
    initial: []Point = &.{}, // Starting storage-zone position of each qubit, frozen at placement time.
    t: u32 = 0,

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

    pub fn moveSlmCompute(
        s: *Physical,
        gpa: std.mem.Allocator,
        cfg: arch.ArchConfig,
        fixed: []const ?usize,
    ) !void {
        var ordered: std.ArrayList(usize) = .empty;
        defer ordered.deinit(gpa);

        var cols: std.ArrayList(usize) = .empty;
        defer cols.deinit(gpa);

        for (fixed, 0..) |maybe_qubit, col| {
            if (maybe_qubit) |q| {
                try ordered.append(gpa, q);
                try cols.append(gpa, col);
            }
        }

        var register = try pickup(gpa, cfg, ordered.items, &s.placement, &s.t);
        defer register.deinit(gpa);

        // Move each atom to its destination slot in compute zone slms[0].
        const control = cfg.compute_zone.slms[0];
        const x_orig = cfg.compute_zone.offset_nm[0] + control.offset_nm[0];
        const y_orig = cfg.compute_zone.offset_nm[1] + control.offset_nm[1];
        const x_sep = @as(i32, @intCast(control.sep_nm[0]));

        // Manhattan step 1: move each atom to its target x column (null slots skipped).
        const d = @as(i32, @intCast(cfg.compute_zone.slms[0].sep_nm[0] / 2));
        for (register.items, cols.items) |a, col| {
            const x_dest = x_orig + @as(i32, @intCast(col)) * x_sep;
            try a.move(x_dest - a.pos.x + d, 0, s.t);
        }
        s.t += 1;

        // Manhattan step 2: move all atoms to the compute zone row.
        const y_dest = y_orig + @as(i32, @intCast(control.sep_nm[1]));
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
                try s.ops.append(gpa, o);
            }
        }
    }

    pub fn moveSlmStorage(
        s: *Physical,
        gpa: std.mem.Allocator,
        cfg: arch.ArchConfig,
        fixed: []const ?usize,
    ) !void {
        const cslm = cfg.compute_zone.slms[0];
        // Half compute zone site spacing — used as clearance from trap sites.
        const d_c: i32 = @intCast(cslm.sep_nm[0] / 2);
        // Upper edge of the compute zone (top SLM row y, with d_c clearance).
        const y_compute_upper: i32 = cfg.compute_zone.offset_nm[1] + cslm.offset_nm[1] - d_c;
        // Bottom edge of the storage zone (bottom SLM row y, closest to compute).
        const sslm = cfg.storage_zone.slm;
        const y_storage_bottom: i32 = cfg.storage_zone.offset_nm[1] + sslm.offset_nm[1] +
            @as(i32, @intCast((sslm.num_row - 1) * sslm.sep_nm[1]));
        // Corridor: upper compute edge plus half the inter-zone gap — trap-free, safe for x alignment.
        const half_sep: i32 = @divTrunc(cfg.compute_zone.offset_nm[1] + cslm.offset_nm[1] - y_storage_bottom, 2);
        const y_corridor: i32 = y_compute_upper - half_sep;

        // Load each atom into the AOD so the horizontal highlight shows during the return trip.
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| {
                try s.ops.append(gpa, .{
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
                try s.ops.append(gpa, .{
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
                try s.ops.append(gpa, .{
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
        const x_s_orig: i32 = cfg.storage_zone.offset_nm[0] + sslm.offset_nm[0];
        const x_s_sep: i32 = @intCast(sslm.sep_nm[0]);
        var returning: std.ArrayList(usize) = .empty;
        defer returning.deinit(gpa);
        for (fixed) |maybe_slm| {
            if (maybe_slm) |q| try returning.append(gpa, q);
        }

        var occ = try occupiedStorageX(gpa, returning.items, s.placement, y_storage_bottom);
        defer occ.deinit();

        var col: usize = 0;
        for (returning.items) |q| {
            while (occ.contains(x_s_orig + @as(i32, @intCast(col)) * x_s_sep)) col += 1;
            const dest_x = x_s_orig + @as(i32, @intCast(col)) * x_s_sep;
            const src = s.placement[q].pos;
            if (src.x != dest_x) {
                try s.ops.append(gpa, .{
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
                    try s.ops.append(gpa, .{
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
                try s.ops.append(gpa, .{
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

    pub fn moveAodStorage(
        s: *Physical,
        gpa: std.mem.Allocator,
        cfg: arch.ArchConfig,
        aod_qubits: [][]?usize,
    ) !void {
        // Collect all unique qubit IDs across all timeframes.
        var seen = std.AutoHashMap(usize, void).init(gpa);
        defer seen.deinit();

        var unique: std.ArrayList(usize) = .empty;
        defer unique.deinit(gpa);

        for (aod_qubits) |row| {
            for (row) |maybe_q| {
                if (maybe_q) |q| {
                    const gop = try seen.getOrPut(q);
                    if (!gop.found_existing) try unique.append(gpa, q);
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
            try s.ops.append(gpa, .{
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

        const cslm = cfg.compute_zone.slms[0];
        const d_c: i32 = @intCast(cslm.sep_nm[0] / 2);
        const y_compute_upper: i32 = cfg.compute_zone.offset_nm[1] + cslm.offset_nm[1] - d_c;
        const sslm = cfg.storage_zone.slm;
        const y_storage_bottom: i32 = cfg.storage_zone.offset_nm[1] + sslm.offset_nm[1] +
            @as(i32, @intCast((sslm.num_row - 1) * sslm.sep_nm[1]));
        const half_sep: i32 = @divTrunc(cfg.compute_zone.offset_nm[1] + cslm.offset_nm[1] - y_storage_bottom, 2);
        const y_corridor: i32 = y_compute_upper - half_sep;

        // Step 1: move RIGHT by d_c — shift into inter-column lane.
        for (unique.items) |q| {
            const src = s.placement[q].pos;
            const dest = Point{ .x = src.x + d_c, .y = src.y };
            try s.ops.append(gpa, .{
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
            try s.ops.append(gpa, .{
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
        const x_s_orig: i32 = cfg.storage_zone.offset_nm[0] + sslm.offset_nm[0];
        const x_s_sep: i32 = @intCast(sslm.sep_nm[0]);

        var occ = try occupiedStorageX(gpa, unique.items, s.placement, y_storage_bottom);
        defer occ.deinit();

        var col: usize = 0;
        for (unique.items) |q| {
            while (occ.contains(x_s_orig + @as(i32, @intCast(col)) * x_s_sep)) col += 1;
            const dest_x = x_s_orig + @as(i32, @intCast(col)) * x_s_sep;
            const src = s.placement[q].pos;
            if (src.x != dest_x) {
                try s.ops.append(gpa, .{
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
                try s.ops.append(gpa, .{
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
            try s.ops.append(gpa, .{
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

    pub fn moveAodCompute(
        s: *Physical,
        gpa: std.mem.Allocator,
        cfg: arch.ArchConfig,
        moveable: [][]?usize,
    ) !void {
        // Collect all unique qubit IDs across all timeframes.
        var ordered: std.ArrayList(usize) = .empty;
        defer ordered.deinit(gpa);

        var seen = std.AutoHashMap(usize, void).init(gpa);
        defer seen.deinit();

        for (moveable) |row| {
            for (row) |maybe_q| {
                if (maybe_q) |q| {
                    const gop = try seen.getOrPut(q);
                    if (!gop.found_existing) try ordered.append(gpa, q);
                }
            }
        }
        if (ordered.items.len == 0) return;

        // Pick up atoms from storage, traversing without crossing occupied sites.
        var register = try pickup(gpa, cfg, ordered.items, &s.placement, &s.t);
        defer register.deinit(gpa);

        // Manhattan entry into SLM[1] — mirrors moveSlmCompute for SLM[0].
        const target = cfg.compute_zone.slms[1];
        const x_orig = cfg.compute_zone.offset_nm[0] + target.offset_nm[0];
        const y_orig = cfg.compute_zone.offset_nm[1] + target.offset_nm[1];
        const x_sep = @as(i32, @intCast(target.sep_nm[0]));
        const d = @as(i32, @intCast(target.sep_nm[0] / 2));

        // Step 1: move each atom to its column x + d (inter-column offset avoids crossings).
        for (register.items, 0..) |a, i| {
            const x_dest = x_orig + @as(i32, @intCast(i)) * x_sep;
            try a.move(x_dest - a.pos.x + d, 0, s.t);
        }
        s.t += 1;

        // Step 2: drop all atoms to SLM[1] row y.
        const y_dest = y_orig + @as(i32, @intCast(target.sep_nm[1]));
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
                try s.ops.append(gpa, o);
            }
        }

        // Sweep: for each timeframe, lift atoms into AOD (t), slide to column (t),
        // then deposit back into SLM (t+1, red flash). Store only fires when atoms moved.
        for (moveable) |row| {
            var moved_q: std.ArrayList(usize) = .empty;
            defer moved_q.deinit(gpa);

            for (row, 0..) |maybe_q, i| {
                if (maybe_q) |q| {
                    const dest_x = x_orig + @as(i32, @intCast(i)) * x_sep;
                    const src = s.placement[q].pos;
                    if (src.x == dest_x) continue;
                    try s.ops.append(gpa, .{
                        .t = s.t,
                        .kind = .{
                            .load = .{
                                .qubit = @intCast(q),
                                .position = src,
                            },
                        },
                    });
                    try s.ops.append(gpa, .{
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
                    try moved_q.append(gpa, q);
                }
            }
            s.t += 1;

            for (moved_q.items) |q| {
                try s.ops.append(gpa, .{
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

    pub fn writeToFile(self: *const Physical, gpa: std.mem.Allocator, io: std.Io, filename: []const u8) !void {
        const json = try self.toJson(gpa);
        defer gpa.free(json);

        const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
        defer file.close(io);
        try file.writePositionalAll(io, json, 0);
    }

    pub fn toJson(self: *const Physical, gpa: std.mem.Allocator) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        const w = &buf.writer;

        try w.writeAll("{\n");
        try w.writeAll("  \"version\": \"1.1\",\n");
        try w.writeAll("  \"platform\": \"taiyi-v1\",\n");
        try w.print("  \"num_qubits\": {d},\n", .{self.placement.len});
        try w.writeAll("  \"ops\": [\n");

        for (self.ops, 0..) |op, i| {
            const last_op = i == self.ops.len - 1;
            try w.writeAll("    {\n");
            switch (op.kind) {
                .raman => |r| {
                    try w.writeAll("      \"op\": \"raman\",\n");
                    try w.print("      \"angle\": {d:.4},\n", .{r.angle});
                    try w.print("      \"phase\": {d:.4},\n", .{r.phase});
                    try w.print("      \"t\": {d},\n", .{op.t});
                    try w.writeAll("      \"targets\": [\n");
                    for (r.targets, 0..) |target, j| {
                        const last = j == r.targets.len - 1;
                        try w.print("        {{ \"qubit\": {d}, \"x\": {d}, \"y\": {d} }}", .{ target.qubit, target.pos.x, target.pos.y });
                        try w.writeAll(if (last) "\n" else ",\n");
                    }
                    try w.writeAll("      ]\n");
                },
                .move => |m| {
                    try w.writeAll("      \"op\": \"move\",\n");
                    try w.print("      \"aod\": {d},\n", .{m.aod});
                    try w.print("      \"translate\": \"{s}\",\n", .{@tagName(m.translate)});
                    try w.print("      \"from_zone\": \"{s}\",\n", .{zoneName(m.src_zone)});
                    try w.print("      \"to_zone\": \"{s}\",\n", .{zoneName(m.dest_zone)});
                    try w.print("      \"t\": {d},\n", .{op.t});
                    try w.writeAll("      \"atoms\": [\n");
                    for (m.atoms, 0..) |atom, j| {
                        const last = j == m.atoms.len - 1;
                        try w.writeAll("        {\n");
                        try w.print("          \"qubit\": {d},\n", .{atom.qubit});
                        try w.print("          \"from\": {{ \"x\": {d}, \"y\": {d} }},\n", .{ atom.src.x, atom.src.y });
                        try w.print("          \"to\": {{ \"x\": {d}, \"y\": {d} }}\n", .{ atom.dest.x, atom.dest.y });
                        try w.writeAll(if (last) "        }\n" else "        },\n");
                    }
                    try w.writeAll("      ]\n");
                },
                .rydberg => |r| {
                    try w.writeAll("      \"op\": \"rydberg\",\n");
                    try w.print("      \"zone\": \"{s}\",\n", .{zoneName(r.zone)});
                    try w.print("      \"t\": {d}\n", .{op.t});
                },
                .measure => |m| {
                    try w.writeAll("      \"op\": \"measure\",\n");
                    try w.print("      \"zone\": \"{s}\",\n", .{zoneName(m.zone)});
                    try w.writeAll("      \"basis\": \"Z\",\n");
                    try w.print("      \"t\": {d},\n", .{op.t});
                    try w.writeAll("      \"qubits\": [");
                    for (m.qubits, 0..) |q, j| {
                        if (j > 0) try w.writeAll(", ");
                        try w.print("{d}", .{q});
                    }
                    try w.writeAll("]\n");
                },
                .load => |ld| {
                    try w.writeAll("      \"op\": \"load\",\n");
                    try w.print("      \"qubit\": {d},\n", .{ld.qubit});
                    try w.print("      \"x\": {d},\n", .{ld.position.x});
                    try w.print("      \"y\": {d},\n", .{ld.position.y});
                    try w.print("      \"t\": {d}\n", .{op.t});
                },
                .store => |st| {
                    try w.writeAll("      \"op\": \"store\",\n");
                    try w.print("      \"qubit\": {d},\n", .{st.qubit});
                    try w.print("      \"x\": {d},\n", .{st.position.x});
                    try w.print("      \"y\": {d},\n", .{st.position.y});
                    try w.print("      \"t\": {d}\n", .{op.t});
                },
            }
            try w.writeAll(if (last_op) "    }\n" else "    },\n");
        }

        try w.writeAll("  ]\n");
        try w.writeAll("}");

        return gpa.dupe(u8, buf.written());
    }
};

fn zoneName(z: Zone) []const u8 {
    return switch (z) {
        .storage => "storage",
        .compute => "compute",
        .readout => "readout_zone",
    };
}

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

pub fn pickup(
    gpa: std.mem.Allocator,
    cfg: arch.ArchConfig,
    ord: []const usize,
    plc: *[]Atom,
    t: *u32,
) !Register {
    const d = @as(i32, @intCast(cfg.storage_zone.slm.sep_nm[0] / 2));

    var register: Register = .empty;
    errdefer register.deinit(gpa);

    if (ord.len == 0) return register;

    // Pick up first atom.
    try pickUpAtom(&register, gpa, &plc.*[ord[0]], t.*);
    t.* += 1;
    var front = plc.*[ord[0]];

    // Move the registered atoms to always make the
    // next qubit the front of the row.
    for (ord[1..]) |q| {
        const next = plc.*[q];

        if (next.isLeftOf(front)) {
            const dx: i32 = front.pos.x - next.pos.x;
            for (register.items) |*atom| try atom.*.moveUp(@intCast(d), t.*);
            t.* += 1;
            for (register.items) |*atom| try atom.*.moveLeft(@intCast(dx + d), t.*);
            t.* += 1;
            // Before descending, shift any atom that would land on an occupied site.
            var conflict = true;
            while (conflict) {
                conflict = false;
                for (register.items) |*atom| {
                    if (siteOccupied(register, plc.*, atom.*.pos.x, atom.*.pos.y + d)) {
                        try atom.*.moveLeft(@intCast(d), t.*);
                        conflict = true;
                    }
                }
                if (conflict) t.* += 1;
            }
            for (register.items) |*atom| try atom.*.moveDown(@intCast(d), t.*);
            t.* += 1;
        }

        try pickUpAtom(&register, gpa, &plc.*[q], t.*);
        t.* += 1;
        front = next;
    }

    // Move all loaded atoms down together at the same timestep.
    for (register.items) |*a| {
        try a.*.moveDown(@intCast(4 * d), t.*);
    }
    t.* += 1;

    return register;
}

pub fn addRamanOp(
    gpa: std.mem.Allocator,
    placement: []const Point,
    u_gates: []const circuit.U,
    t: u32,
    ops: *std.ArrayList(Op),
) !void {
    // FIXME, do we need a list of targets?
    for (u_gates) |gate| {
        var targets: std.ArrayList(RamanTarget) = .empty;

        try targets.append(gpa, .{
            .qubit = @intCast(gate.qubit),
            .pos = placement[gate.qubit],
        });

        try ops.append(gpa, Op{
            .t = t,
            .kind = .{
                .raman = .{
                    .angle = gate.theta,
                    .phase = gate.phi,
                    .targets = try targets.toOwnedSlice(gpa),
                },
            },
        });
    }
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

// Place qubits in storage zone as defined by the
// upstream Atom Assembly (Atom Rearrangement).
pub fn assemble(
    gpa: std.mem.Allocator,
    sz: arch.StorageZone,
    num_qubits: usize,
) !Physical {
    const x_orig = sz.offset_nm[0] + sz.slm.offset_nm[0];
    const y_orig = sz.offset_nm[1] + sz.slm.offset_nm[1];
    const x_sep = @as(i32, @intCast(sz.slm.sep_nm[0]));
    const y_sep = @as(i32, @intCast(sz.slm.sep_nm[1]));

    const num_col = sz.slm.num_col;
    const num_row = sz.slm.num_row;

    // Center half: columns from 25% to 75% of the grid width.
    const col_start = num_col / 4;
    const col_end = num_col - num_col / 4;

    var sites: std.ArrayList(Point) = .empty;
    defer sites.deinit(gpa);

    for (0..num_row) |row| {
        const i = num_row - 1 - row;
        for (col_start..col_end) |j| {
            try sites.append(gpa, Point{
                .x = x_orig + @as(i32, @intCast(j)) * x_sep,
                .y = y_orig + @as(i32, @intCast(i)) * y_sep,
            });
        }
    }

    const plc = try gpa.alloc(Atom, num_qubits);
    for (plc, 0..) |*p, i| {
        p.* = try Atom.place(gpa, i, sites.items[i]);
    }

    var physical = Physical{ .gpa = gpa };
    physical.placement = plc;
    physical.initial = try gpa.alloc(Point, physical.placement.len);
    for (physical.placement, physical.initial) |atom, *p| p.* = atom.pos;

    return physical;
}
