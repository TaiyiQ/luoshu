const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");

pub const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

pub const Atom = struct {
    allocator: std.mem.Allocator,
    id: u32,
    pos: Point,
    ops: std.ArrayList(Op),

    fn init(allocator: std.mem.Allocator, id: usize, pos: Point) !Atom {
        return .{
            .allocator = allocator,
            .id = @as(u32, @intCast(id)),
            .pos = pos,
            .ops = .empty,
        };
    }

    pub fn deinit(s: *Atom) void {
        s.ops.deinit(s.allocator);
    }

    fn load(s: *Atom, t: u32) !void {
        try s.ops.append(s.allocator, .{ .t = t, .kind = .{
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
        try s.ops.append(s.allocator, .{ .t = t, .kind = .{
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
    sites: []const Point, // All SLM trap sites across storage and compute zones.

    pub fn deinit(s: *Physical) void {
        for (s.ops) |op| {
            switch (op.kind) {
                .raman => |r| s.allocator.free(r.targets),
                .measure => |m| s.allocator.free(m.qubits),
                .rydberg, .load, .move, .store => {},
            }
        }
        s.allocator.free(s.ops);
        for (s.placement) |*p| p.deinit();
        s.allocator.free(s.placement);
        s.allocator.free(s.sites);
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
pub fn allSlmSites(allocator: std.mem.Allocator, layout: arch.ArchConfig) ![]const Point {
    var sites: std.ArrayList(Point) = .empty;

    {
        const slm = layout.storage_zone.slm;
        const x0 = layout.storage_zone.offset_nm[0] + slm.offset_nm[0];
        const y0 = layout.storage_zone.offset_nm[1] + slm.offset_nm[1];
        const x_sep_s: i32 = @intCast(slm.sep_nm[0]);
        const y_sep_s: i32 = @intCast(slm.sep_nm[1]);
        for (0..slm.num_row) |ri| for (0..slm.num_col) |ci| {
            try sites.append(allocator, .{
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
            try sites.append(allocator, .{
                .x = x0 + @as(i32, @intCast(ci)) * x_sep_s,
                .y = y0 + @as(i32, @intCast(ri)) * y_sep_s,
            });
        };
    }

    return try sites.toOwnedSlice(allocator);
}

/// Indexed by qubit id; null means the atom hasn't been picked up.
/// Backed by a single allocation sized to the number of sites.
pub const Register = std.ArrayList(*Atom);

fn pickUpAtom(
    register: *Register,
    allocator: std.mem.Allocator,
    atom: *Atom,
    t: u32,
) !void {
    try atom.load(t);
    try register.append(allocator, atom);
}

pub fn pickup(
    allocator: std.mem.Allocator,
    cfg: arch.ArchConfig,
    ord: []const usize,
    plc: *[]Atom,
) !Register {
    const d = @as(i32, @intCast(cfg.storage_zone.slm.sep_nm[0] / 2));

    var register: Register = .empty;
    errdefer register.deinit(allocator);

    if (ord.len == 0) return register;

    var t: u32 = 0;

    // Pick up first atom.
    try pickUpAtom(&register, allocator, &plc.*[ord[0]], t);
    t += 1;
    var frontier = plc.*[ord[0]];

    for (ord[1..]) |q| {
        var home = plc.*[q];

        // Manhattan slide: rise above the SLM plane, move left, descend.
        // This avoids crossing any fixed atoms still sitting in their traps.
        if (home.isLeftOf(frontier)) {
            const dx: i32 = frontier.pos.x - home.pos.x;
            for (register.items) |*atom| try atom.*.moveUp(@intCast(d), t);
            t += 1;
            for (register.items) |*atom| try atom.*.moveLeft(@intCast(dx + d), t);
            t += 1;
            for (register.items) |*atom| try atom.*.moveDown(@intCast(d), t);
            t += 1;
        }

        try pickUpAtom(&register, allocator, &plc.*[q], t);
        t += 1;
        frontier = home;
    }

    // Move all loaded atoms down together at the same timestep.
    for (register.items) |*a| {
        try a.*.moveDown(@intCast(4 * d), t);
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
    var ordered: std.ArrayList(usize) = .empty;
    defer ordered.deinit(allocator);
    for (fixed_qubits) |maybe_qubit| {
        if (maybe_qubit) |q| try ordered.append(allocator, q);
    }

    var register = try pickup(allocator, cfg, ordered.items, placement);
    defer register.deinit(allocator);

    // Find the next timestep after the pickup sequence ends.
    var next_t: u32 = t;
    for (register.items) |a| {
        if (a.ops.items.len > 0) {
            const last_t = a.ops.items[a.ops.items.len - 1].t;
            if (last_t >= next_t) next_t = last_t + 1;
        }
    }

    // Move each atom to its destination slot in compute zone slms[0].
    const control = cfg.compute_zone.slms[0];
    const x_orig = cfg.compute_zone.offset_nm[0] + control.offset_nm[0];
    const y_orig = cfg.compute_zone.offset_nm[1] + control.offset_nm[1];
    const x_sep = @as(i32, @intCast(control.sep_nm[0]));

    // Manhattan step 1: move each atom to its target x column.
    for (register.items, 0..) |a, i| {
        const x_dest = x_orig + @as(i32, @intCast(i)) * x_sep;
        try a.move(x_dest - a.pos.x, 0, next_t);
    }
    next_t += 1;

    // Manhattan step 2: move all atoms to the compute zone row.
    const y_dest = y_orig + @as(i32, @intCast(control.sep_nm[1]));
    for (register.items) |a| {
        try a.move(0, y_dest - a.pos.y, next_t);
    }

    // Flush pickup + compute-zone move ops to the global ops list.
    for (register.items) |a| {
        for (a.ops.items) |o| {
            try ops.append(allocator, o);
        }
    }
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
