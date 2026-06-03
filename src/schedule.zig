// Schedule opartions.

const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");

pub const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

pub const Point = struct { x: i32, y: i32 };
const RamanTarget = struct { qubit: u32, pos: Point };
const MoveAtom = struct { qubit: u32, src: Point, dest: Point };

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

// TODO: Make sure a moving atom has been loaded before.
const Move = struct {
    aod: u32,
    translate: Axis,
    src_zone: Zone,
    dest_zone: Zone,
    atoms: []const MoveAtom,
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
    placement: []Point, // Initial storage-zone position of each qubit (index = qubit id).
    slots: []const Point, // All SLM trap sites across storage and compute zones.

    pub fn deinit(s: *Physical) void {
        for (s.ops) |op| {
            switch (op.kind) {
                .move => |m| s.allocator.free(m.atoms),
                .raman => |r| s.allocator.free(r.targets),
                .measure => |m| s.allocator.free(m.qubits),
                .rydberg, .load, .store => {},
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

// A qubit set to have fast lookup on which qubits have been picked up.
const Register = std.AutoHashMap(usize, void);

// Pick up atoms into the moveable register.
// Pick up does include Manhattan moves to each atom.
// They have to architecture aware in order not to cross sites.
pub fn pickup(
    allocator: std.mem.Allocator,
    cfg: arch.ArchConfig,
    fixed_qubits: []const ?usize,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
) !Register {
    var register = Register.init(allocator);

    // FIXME: for now, just move it down a bit. Will do proper spacing later on.
    const d = cfg.storage_zone.slm.sep_nm[0] / 2;

    for (fixed_qubits) |maybe_qubit| {
        if (maybe_qubit) |q| {
            var src = placement.*[q];

            // FIXME: Set proper timeframe.
            var op = Op{ .t = 0, .kind = .{
                .load = .{
                    .qubit = @as(u32, @intCast(q)),
                    .position = src,
                },
            } };
            try ops.append(allocator, op);

            var atoms: std.ArrayList(MoveAtom) = .empty;

            src.y += @as(i32, @intCast(d));

            try atoms.append(allocator, MoveAtom{
                .qubit = @as(u32, @intCast(q)),
                .src = src,
                .dest = .{ .x = src.x, .y = src.y },
            });

            op = Op{ .t = 0, .kind = .{
                .move = .{
                    .aod = 0,
                    .translate = Axis.y,
                    .src_zone = Zone.storage,
                    .dest_zone = Zone.compute,
                    .atoms = try atoms.toOwnedSlice(allocator),
                },
            } };
            try ops.append(allocator, op);

            try register.put(q, {});
        }
    }

    return register;
}

pub fn moveSlmCompute(
    allocator: std.mem.Allocator,
    cfg: arch.ArchConfig,
    fixed_qubits: []const ?usize,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
    t: u32,
) !void {
    // FIXME: mayube we dont need a register, since we will always pickup the current set?
    var register = try pickup(allocator, cfg, fixed_qubits, placement, ops);
    defer register.deinit();

    const cz = cfg.compute_zone;

    const control = cz.slms[0];
    const x_slm_orig = cz.offset_nm[0] + control.offset_nm[0];
    const y_slm_orig = cz.offset_nm[1] + control.offset_nm[1];
    const x_sep = control.sep_nm[0];

    var atoms: std.ArrayList(MoveAtom) = .empty;

    for (fixed_qubits, 0..) |maybe_qubit, i| {
        const x = x_slm_orig + @as(i32, @intCast(i)) * @as(i32, @intCast(x_sep));
        const y = y_slm_orig + @as(i32, @intCast(control.sep_nm[1]));

        if (maybe_qubit) |qubit_id| {
            const src = placement.*[qubit_id];
            const dest = Point{ .x = x, .y = y };

            try atoms.append(allocator, MoveAtom{
                .qubit = @as(u32, @intCast(qubit_id)),
                .src = src,
                .dest = dest,
            });

            // Update to qubit location.
            placement.*[qubit_id] = dest;
        }
    }

    const op = Op{ .t = t, .kind = .{
        .move = .{
            .aod = 0,
            .translate = Axis.y,
            .src_zone = Zone.storage,
            .dest_zone = Zone.compute,
            .atoms = try atoms.toOwnedSlice(allocator),
        },
    } };

    try ops.append(allocator, op);
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
    var atoms: std.ArrayList(MoveAtom) = .empty;

    for (slm_qubits) |maybe_slm| {
        if (maybe_slm) |qubit_id| {
            const src = placement.*[qubit_id];
            const dest = init_placement[qubit_id];

            try atoms.append(allocator, MoveAtom{
                .qubit = @as(u32, @intCast(qubit_id)),
                .src = src,
                .dest = dest,
            });

            placement.*[qubit_id] = dest;
        }
    }

    const op = Op{ .t = t, .kind = .{
        .move = .{
            .aod = 0,
            .translate = Axis.y,
            .src_zone = Zone.compute,
            .dest_zone = Zone.storage,
            .atoms = try atoms.toOwnedSlice(allocator),
        },
    } };

    try ops.append(allocator, op);
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
        var atoms: std.ArrayList(MoveAtom) = .empty;

        for (aod_row) |maybe_aod| {
            if (maybe_aod) |qubit_id| {
                const src = placement.*[qubit_id];
                const dest = init_placement[qubit_id];

                try atoms.append(allocator, MoveAtom{
                    .qubit = @as(u32, @intCast(qubit_id)),
                    .src = src,
                    .dest = dest,
                });

                // Update new qubit location.
                placement.*[qubit_id] = dest;
            }
        }

        const op_t = t_base + @as(u32, @intCast(t));
        const op = Op{ .t = op_t, .kind = .{
            .move = .{
                .aod = 0,
                .translate = Axis.y,
                .src_zone = Zone.compute,
                .dest_zone = Zone.storage,
                .atoms = try atoms.toOwnedSlice(allocator),
            },
        } };

        try ops.append(allocator, op);
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
        var atoms: std.ArrayList(MoveAtom) = .empty;

        for (aod_row, 0..) |maybe_aod, i| {
            const x = x_aod_orig + @as(i32, @intCast(i)) * @as(i32, @intCast(x_aod_sep));
            const y = y_aod_orig + @as(i32, @intCast(target.sep_nm[1]));

            if (maybe_aod) |qubit_id| {
                const src = placement.*[qubit_id];
                const dest = Point{ .x = x, .y = y };

                try atoms.append(allocator, MoveAtom{
                    .qubit = @as(u32, @intCast(qubit_id)),
                    .src = src,
                    .dest = dest,
                });

                // Update new qubit location.
                placement.*[qubit_id] = dest;
            }
        }

        const op_t = t_base + @as(u32, @intCast(t));
        const op = Op{ .t = op_t, .kind = .{
            .move = .{
                .aod = 0,
                .translate = Axis.y,
                .src_zone = Zone.compute,
                .dest_zone = Zone.compute,
                .atoms = try atoms.toOwnedSlice(allocator),
            },
        } };

        try ops.append(allocator, op);

        try ops.append(allocator, Op{
            .t = op_t,
            .kind = .{ .rydberg = .{ .zone = Zone.compute } },
        });
    }
}

pub fn qubitPlacement(
    allocator: std.mem.Allocator,
    sz: arch.StorageZone,
    slm_slots: []const ?usize,
    aod_slots: [][]?usize,
    num_qubits: usize,
) ![]Point {
    var tmp = try allocator.alloc(?Point, num_qubits);
    defer allocator.free(tmp);
    @memset(tmp, null);

    // Relative starting origin of grid (bottom-left).
    const x_orig = sz.offset_nm[0] + sz.slm.offset_nm[0];
    const y_orig = sz.offset_nm[1] + sz.slm.offset_nm[1];

    // Seperation spacing between grid items.
    const x_sep = @as(i32, @intCast(sz.slm.sep_nm[0]));
    const y_sep = @as(i32, @intCast(sz.slm.sep_nm[1]));

    var sites: std.ArrayList(Point) = .empty;
    defer sites.deinit(allocator);
    for (0..sz.slm.num_row) |row| {
        // Start from the row closest to the compute zone.
        const i = sz.slm.num_row - 1 - row;
        for (0..sz.slm.num_col) |j| {
            try sites.append(allocator, Point{
                .x = x_orig + @as(i32, @intCast(j)) * x_sep,
                .y = y_orig + @as(i32, @intCast(i)) * y_sep,
            });
        }
    }

    var qubit_id: usize = 0;

    // 1. Place SLM qubits (those involved in CZ gates, fixed traps).
    for (slm_slots) |maybe_qubit| {
        if (maybe_qubit) |id| {
            tmp[id] = sites.items[qubit_id];
            qubit_id += 1;
        }
    }

    // 2. Place AOD qubits (those involved in CZ gates, mobile traps).
    for (aod_slots[0]) |maybe_qubit| {
        if (maybe_qubit) |id| {
            tmp[id] = sites.items[qubit_id];
            qubit_id += 1;
        }
    }

    // 3. Place isolated qubits (U-gate-only, not in any CZ) in remaining sites.
    for (0..num_qubits) |id| {
        if (tmp[id] == null) {
            tmp[id] = sites.items[qubit_id];
            qubit_id += 1;
        }
    }

    // Ensure all qubits are placed.
    const placement = try allocator.alloc(Point, num_qubits);
    for (tmp, placement) |maybe_p, *out| out.* = maybe_p.?;

    return placement;
}
