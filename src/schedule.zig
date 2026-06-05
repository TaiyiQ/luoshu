const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");

pub const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

pub const Atom = struct {
    allocator: std.mem.Allocator,
    id: u32,
    t: u32,
    pos: Point,
    ops: std.ArrayList(Op),

    fn init(allocator: std.mem.Allocator, id: usize, pos: Point) !Atom {
        return .{
            .allocator = allocator,
            .id = @as(u32, @intCast(id)),
            .t = 0,
            .pos = pos,
            .ops = .empty,
        };
    }

    pub fn deinit(s: *Atom) void {
        s.ops.deinit(s.allocator);
    }

    fn load(s: *Atom) !void {
        try s.ops.append(s.allocator, .{ .t = s.t, .kind = .{ .load = .{ .qubit = s.id, .position = s.pos } } });
        s.t += 1;
    }

    fn move(s: *Atom, dx: i32, dy: i32) !void {
        const src = s.pos;
        s.pos.x += dx;
        s.pos.y += dy;
        try s.ops.append(s.allocator, .{ .t = s.t, .kind = .{ .move = .{ .qubit = s.id, .src = src, .dest = s.pos } } });
        s.t += 1;
    }

    fn moveLeft(s: *Atom, d: u32) !void {
        try s.move(-@as(i32, @intCast(d)), 0);
    }

    fn moveRight(s: *Atom, d: u32) !void {
        try s.move(@intCast(d), 0);
    }

    fn moveUp(s: *Atom, d: u32) !void {
        try s.move(0, -@as(i32, @intCast(d)));
    }

    fn moveDown(s: *Atom, d: u32) !void {
        try s.move(0, @intCast(d));
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

const Raman = struct {
    angle: f64,
    phase: f64,
    targets: []const RamanTarget,
};

const Load = struct {
    qubit: u32,
    position: Point,
};

const Store = struct {
    qubit: u32,
    position: Point,
};

const Move = struct {
    qubit: u32,
    src: Point,
    dest: Point,
};

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
    allocator: std.mem.Allocator,
    ops: []const Op,
    placement: []Atom, // Initial storage-zone position of each qubit (index = qubit id).
    slots: []const Point, // All SLM trap sites across storage and compute zones.

    pub fn deinit(s: *Physical) void {
        for (s.ops) |op| {
            switch (op.kind) {
                .raman => |r| s.allocator.free(r.targets),
                .measure => |m| s.allocator.free(m.qubits),
                .rydberg, .load, .move, .store => {},
            }
        }
        s.allocator.free(s.ops);
        s.allocator.free(s.placement);
        s.allocator.free(s.slots);
    }

    pub fn writeToFile(self: *const Physical, allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !void {
        const json = try self.toJson(allocator);
        defer allocator.free(json);

        const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
        defer file.close(io);
        try file.writePositionalAll(io, json, 0);
    }

    pub fn toJson(self: *const Physical, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
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

        return allocator.dupe(u8, buf.written());
    }
};

fn zoneName(z: Zone) []const u8 {
    return switch (z) {
        .storage => "storage",
        .compute => "compute",
        .readout => "readout_zone",
    };
}

// Enumerate every SLM trap site across storage and compute zones. These are drawn
// as background indicators in the visualization.
pub fn allSlmSlots(allocator: std.mem.Allocator, layout: arch.ArchConfig) ![]const Point {
    var slots: std.ArrayList(Point) = .empty;

    {
        const slm = layout.storage_zone.slm;
        const x0 = layout.storage_zone.offset_nm[0] + slm.offset_nm[0];
        const y0 = layout.storage_zone.offset_nm[1] + slm.offset_nm[1];
        const x_sep_s: i32 = @intCast(slm.sep_nm[0]);
        const y_sep_s: i32 = @intCast(slm.sep_nm[1]);
        for (0..slm.num_row) |ri| for (0..slm.num_col) |ci| {
            try slots.append(allocator, .{
                .x = x0 + @as(i32, @intCast(ci)) * x_sep_s,
                .y = y0 + @as(i32, @intCast(ri)) * y_sep_s,
            });
        };
    }

    for (layout.compute_zone.slms) |slm| {
        const x0 = layout.compute_zone.offset_nm[0] + slm.offset_nm[0];
        const y0 = layout.compute_zone.offset_nm[1] + slm.offset_nm[1];
        const x_sep_s: i32 = @intCast(slm.sep_nm[0]);
        const y_sep_s: i32 = @intCast(slm.sep_nm[1]);
        for (0..slm.num_row) |ri| for (0..slm.num_col) |ci| {
            try slots.append(allocator, .{
                .x = x0 + @as(i32, @intCast(ci)) * x_sep_s,
                .y = y0 + @as(i32, @intCast(ri)) * y_sep_s,
            });
        };
    }

    return try slots.toOwnedSlice(allocator);
}

/// Indexed by qubit id; null means the atom hasn't been picked up.
/// Backed by a single allocation sized to the number of sites.
pub const Register = std.ArrayList(*Atom);

fn pickUpAtom(
    register: *Register,
    allocator: std.mem.Allocator,
    atom: *Atom,
    d: i32,
) !void {

    // Move all registed atoms to be in the same row with
    // atom to be picked up, since physically represents
    // the AOD row.
    //var atom = try Atom.init(allocator, id, p);
    try atom.load();
    //try atom.moveDown(@intCast(d));
    //    try atom.moveLeft(@intCast(d));
    try register.append(allocator, atom);

    // Then, move it back down again to be transported.
    for (register.items) |*a| {
        try a.*.moveDown(@intCast(d));
    }
}

pub fn pickup(
    allocator: std.mem.Allocator,
    cfg: arch.ArchConfig,
    ord: []const usize,
    plc: *[]Atom,
) !Register {

    // FIXME: for now, just move it down a bit. Will do proper spacing later on.
    const d = @as(i32, @intCast(cfg.storage_zone.slm.sep_nm[0] / 2));

    // One slot per site, all empty to start. alloc returns uninitialized
    // memory, so the @memset to null is required before any slot is read.
    var register: Register = .empty;
    errdefer {
        for (register.items) |*atom| atom.*.deinit();
        register.deinit(allocator);
    }

    if (ord.len == 0) return register;

    try pickUpAtom(&register, allocator, &plc.*[ord[0]], d);
    var frontier = plc.*[ord[0]];

    for (ord[1..]) |q| {
        std.debug.print("{}\n", .{q});
        var home = plc.*[q];

        if (!home.isRightOf(frontier)) {
            const dx: i32 = frontier.pos.x - home.pos.x + d;
            for (register.items) |*atom| {
                try atom.*.moveLeft(@intCast(dx));
                try atom.*.moveUp(@intCast(d));
            }
            frontier.pos.x -= dx;
        }

        try pickUpAtom(&register, allocator, &home, d);
        frontier = home;
    }

    return register;
}

pub fn moveSlmCompute(
    allocator: std.mem.Allocator,
    cfg: arch.ArchConfig,
    fixed_qubits: []const ?usize,
    placement: *[]Atom,
    ops: *std.ArrayList(Op),
    t: u32,
) !void {
    // FIXME: mayube we dont need a register, since we will always pickup the current set?
    var ordered: std.ArrayList(usize) = .empty;
    defer ordered.deinit(allocator);
    for (fixed_qubits) |maybe_qubit| {
        if (maybe_qubit) |q| try ordered.append(allocator, q);
    }
    std.debug.print("order:{any}\n", .{ordered});

    var register = try pickup(allocator, cfg, ordered.items, placement);
    defer {
        for (register.items) |*atom| atom.*.deinit();
        register.deinit(allocator);
    }

    std.debug.print("t:{}\n", .{t});

    for (register.items) |a| {
        for (a.ops.items) |o| {
            try ops.append(allocator, o);
        }
    }

    // Calculate movements to the compure zone.

    //    const cz = cfg.compute_zone;
    //    const control = cz.slms[0];
    //    const x_slm_orig = cz.offset_nm[0] + control.offset_nm[0];
    //    const y_slm_orig = cz.offset_nm[1] + control.offset_nm[1];
    //    const x_sep = control.sep_nm[0];

    //    for (register, 0..) |maybe_qubit, i| {
    //        const x = x_slm_orig + @as(i32, @intCast(i)) * @as(i32, @intCast(x_sep));
    //        const y = y_slm_orig + @as(i32, @intCast(control.sep_nm[1]));
    //
    //        if (maybe_qubit) |atom| {
    //            const src = placement.*[atom.id];
    //            const dest = Point{ .x = x, .y = y };
    //
    //            const op = Op{ .t = t, .kind = .{
    //                .move = .{
    //                    .qubit = @as(u32, @intCast(qubit_id)),
    //                    .src = src,
    //                    .dest = dest,
    //                },
    //            } };
    //            try ops.append(allocator, op);
    //
    //            // Update to qubit location.
    //            placement.*[qubit_id] = dest;
    //        }
    //    }
}

pub fn addRamanOp(
    allocator: std.mem.Allocator,
    placement: []const Point,
    u_gates: []const circuit.U,
    t: u32,
    ops: *std.ArrayList(Op),
) !void {
    // FIXME, do we need a list of targets?
    for (u_gates) |gate| {
        var targets: std.ArrayList(RamanTarget) = .empty;

        try targets.append(allocator, .{
            .qubit = @intCast(gate.qubit),
            .pos = placement[gate.qubit],
        });

        try ops.append(allocator, Op{
            .t = t,
            .kind = .{
                .raman = .{
                    .angle = gate.theta,
                    .phase = gate.phi,
                    .targets = try targets.toOwnedSlice(allocator),
                },
            },
        });
    }
}

pub fn moveSlmStorage(
    allocator: std.mem.Allocator,
    slm_qubits: []const ?usize,
    init_placement: []Point,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
    t: u32,
) !void {
    for (slm_qubits) |maybe_slm| {
        if (maybe_slm) |qubit_id| {
            const src = placement.*[qubit_id];
            const dest = init_placement[qubit_id];

            const op = Op{ .t = t, .kind = .{
                .move = .{
                    .qubit = @as(u32, @intCast(qubit_id)),
                    .src = src,
                    .dest = dest,
                },
            } };

            try ops.append(allocator, op);

            placement.*[qubit_id] = dest;
        }
    }
}

pub fn moveAodStorage(
    allocator: std.mem.Allocator,
    aod_qubits: [][]?usize,
    init_placement: []Point,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
    t_base: u32,
) !void {
    for (aod_qubits, 0..) |aod_row, t| {
        for (aod_row) |maybe_aod| {
            if (maybe_aod) |qubit_id| {
                const src = placement.*[qubit_id];
                const dest = init_placement[qubit_id];

                const op_t = t_base + @as(u32, @intCast(t));
                const op = Op{ .t = op_t, .kind = .{
                    .move = .{
                        .qubit = @as(u32, @intCast(qubit_id)),
                        .src = src,
                        .dest = dest,
                    },
                } };

                try ops.append(allocator, op);

                // Update new qubit location.
                placement.*[qubit_id] = dest;
            }
        }
    }
}

pub fn moveAodCompute(
    allocator: std.mem.Allocator,
    cz: arch.ComputeZone,
    aod_qubits: [][]?usize,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
    t_base: u32,
) !void {
    const target = cz.slms[1];
    const x_aod_orig = cz.offset_nm[0] + target.offset_nm[0];
    const y_aod_orig = cz.offset_nm[1] + target.offset_nm[1];
    const x_aod_sep = target.sep_nm[0];

    for (aod_qubits, 0..) |aod_row, t| {
        for (aod_row, 0..) |maybe_aod, i| {
            const x = x_aod_orig + @as(i32, @intCast(i)) * @as(i32, @intCast(x_aod_sep));
            const y = y_aod_orig + @as(i32, @intCast(target.sep_nm[1]));

            if (maybe_aod) |qubit_id| {
                const src = placement.*[qubit_id];
                const dest = Point{ .x = x, .y = y };

                const op_t = t_base + @as(u32, @intCast(t));
                const op = Op{ .t = op_t, .kind = .{
                    .move = .{
                        .qubit = @as(u32, @intCast(qubit_id)),
                        .src = src,
                        .dest = dest,
                    },
                } };

                try ops.append(allocator, op);

                // Update new qubit location.
                placement.*[qubit_id] = dest;
            }
        }

        //        try ops.append(allocator, Op{
        //            .t = op_t,
        //            .kind = .{ .rydberg = .{ .zone = Zone.compute } },
        //        });
    }
}

pub fn qubitPlacement(
    allocator: std.mem.Allocator,
    sz: arch.StorageZone,
    num_qubits: usize,
) ![]Atom {
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
    defer sites.deinit(allocator);
    for (0..num_row) |row| {
        const i = num_row - 1 - row;
        for (col_start..col_end) |j| {
            try sites.append(allocator, Point{
                .x = x_orig + @as(i32, @intCast(j)) * x_sep,
                .y = y_orig + @as(i32, @intCast(i)) * y_sep,
            });
        }
    }

    const placement = try allocator.alloc(Atom, num_qubits);
    for (placement, 0..) |*p, i| {
        p.* = try Atom.init(allocator, i, sites.items[i]);
    }

    return placement;
}
