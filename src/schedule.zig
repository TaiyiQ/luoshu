const std = @import("std");
const arch = @import("arch");

pub const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

pub const Point = struct { x: i32, y: i32 };
const RamanTarget = struct { qubit: u32, pos: Point };
const MoveAtom = struct { qubit: u32, src: Point, dest: Point };

const Raman = struct {
    angle: f32,
    phase: f32,
    targets: []const RamanTarget,
};

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
    move: Move,
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
        s.arena.deinit();
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

    return slots.items;
}

pub fn moveSlmQubits(
    allocator: std.mem.Allocator,
    cz: arch.ComputeZone,
    slm_qubits: []const ?usize,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
    t: u32,
) !void {
    const control = cz.slms[0];
    const x_slm_orig = cz.offset_nm[0] + control.offset_nm[0];
    const y_slm_orig = cz.offset_nm[1] + control.offset_nm[1];
    const x_sep = control.sep_nm[0];

    var atoms: std.ArrayList(MoveAtom) = .empty;

    for (slm_qubits, 0..) |maybe_slm, i| {
        const x = x_slm_orig + @as(i32, @intCast(i)) * @as(i32, @intCast(x_sep));
        const y = y_slm_orig + @as(i32, @intCast(control.sep_nm[1]));

        if (maybe_slm) |qubit_id| {
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
            .atoms = atoms.items,
        },
    } };

    try ops.append(allocator, op);
}

fn addRamanOp(
    allocator: std.mem.Allocator,
    placement: []const Point,
    angle: f32,
    phase: f32,
    t: u32,
    ops: *std.ArrayList(Op),
) !void {
    var targets: std.ArrayList(RamanTarget) = .empty;
    for (placement, 0..) |pos, id| {
        try targets.append(allocator, .{
            .qubit = @intCast(id),
            .pos = pos,
        });
    }
    try ops.append(allocator, Op{
        .t = t,
        .kind = .{ .raman = .{ .angle = angle, .phase = phase, .targets = targets.items } },
    });
}

pub fn moveAodQubits(
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
                .atoms = atoms.items,
            },
        } };

        try ops.append(allocator, op);
        try ops.append(allocator, Op{
            .t = op_t,
            .kind = .{ .rydberg = .{ .zone = Zone.compute } },
        });

        //        // Raman single-qubit layer after each entangling step.
        //        const pi = std.math.pi;
        //        const angle: f32 = if (t % 2 == 0) pi else pi / 2.0;
        //        const phase: f32 = if (t % 2 == 0) 0.0 else pi / 4.0;
        //        try addRamanOp(allocator, placement.*, angle, phase, op_t, ops);
    }
}

pub fn qubitPlacement(
    allocator: std.mem.Allocator,
    sz: arch.StorageZone,
    slm_slots: []const ?usize,
    aod_slots: [][]?usize,
) ![]Point {
    // FIXME: Update the qubit count.
    const max_qubit = sz.slm.num_col * sz.slm.num_row;
    var placement = try allocator.alloc(Point, max_qubit);

    // Relative starting origin of grid (bottom-left).
    const x_orig = sz.offset_nm[0] + sz.slm.offset_nm[0];
    const y_orig = sz.offset_nm[1] + sz.slm.offset_nm[1];

    // Seperation spacing between grid items.
    const x_sep = @as(i32, @intCast(sz.slm.sep_nm[0]));
    const y_sep = @as(i32, @intCast(sz.slm.sep_nm[1]));

    var sites: std.ArrayList(Point) = .empty;
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

    // 1. First move the SLM qubits.
    for (slm_slots) |maybe_qubit| {
        if (maybe_qubit) |id| {
            placement[id] = sites.items[qubit_id];
            qubit_id += 1;
        }
    }

    // 2. Second move the AOD qubits.
    for (aod_slots[0]) |maybe_qubit| {
        if (maybe_qubit) |id| {
            placement[id] = sites.items[qubit_id];
            qubit_id += 1;
        }
    }

    return placement;
}

//pub fn physical(allocator: std.mem.Allocator, layout: arch.ArchConfig, logical: Logical) !Physical {
//    // t = 0: SLM bulk move (storage → compute).
//    // t ≥ 1: one AOD move + Rydberg pulse per logical color, in order.
//    const t_slm: u32 = 0;
//    const t_aod_base: u32 = t_slm + 1;
//
//    var arena = std.heap.ArenaAllocator.init(allocator);
//    errdefer arena.deinit();
//    const alloc = arena.allocator();
//
//    var placement = try qubitPlacement(
//        alloc,
//        layout.storage_zone,
//        logical.slm_slots,
//        logical.aod_slots_per_color,
//    );
//
//    const initial_placement = try alloc.dupe(Point, placement);
//
//    var ops: std.ArrayList(Op) = .empty;
//
//    try moveSlmQubits(
//        alloc,
//        layout.compute_zone,
//        logical.slm_slots,
//        &placement,
//        &ops,
//        t_slm,
//    );
//
//    // Initial single-qubit preparation layer (X rotation on all qubits).
//    //try addRamanOp(alloc, placement, std.math.pi, 0.0, t_slm, &ops);
//
//    try moveAodQubits(
//        alloc,
//        layout.compute_zone,
//        logical.aod_slots_per_color,
//        &placement,
//        &ops,
//        t_aod_base,
//    );
//
//    const slots = try allSlmSlots(alloc, layout);
//
//    return .{
//        .arena = arena,
//        .ops = ops.items,
//        .placement = initial_placement,
//        .slots = slots,
//    };
//}

pub const Logical = struct {
    arena: std.heap.ArenaAllocator,
    slm_slots: []const ?usize,
    aod_slots_per_color: [][]?usize,

    pub fn deinit(self: *Logical) void {
        self.arena.deinit();
    }

    pub fn print(self: Logical) void {
        const n_slots = self.slm_slots.len;

        std.debug.print("\n", .{});

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        std.debug.print(" SLM |", .{});
        for (self.slm_slots) |v| {
            if (v) |id| std.debug.print("{d:^5}|", .{id}) else std.debug.print("  ·  |", .{});
        }
        std.debug.print("\n", .{});

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        for (self.aod_slots_per_color, 0..) |aod_slot, t| {
            std.debug.print("  t{d} |", .{t});
            for (aod_slot, 0..) |v, s| {
                const has_slm = self.slm_slots[s] != null;
                if (v) |id| {
                    if (has_slm) std.debug.print(" {d:^3} |", .{id}) else std.debug.print("{d:^5}|", .{id});
                } else {
                    std.debug.print("  ·  |", .{});
                }
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});
        std.debug.print("\n", .{});
    }

    pub fn toJson(self: *const Logical, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        try w.writeAll("{\n");

        try w.writeAll("  \"slm_slots\": [");
        for (self.slm_slots, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
        }
        try w.writeAll("],\n");

        try w.writeAll("  \"aod_slots_per_color\": [\n");
        for (self.aod_slots_per_color, 0..) |row, ci| {
            try w.writeAll("    [");
            for (row, 0..) |v, i| {
                if (i > 0) try w.writeAll(", ");
                if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
            }
            const last = ci == self.aod_slots_per_color.len - 1;
            try w.writeAll(if (last) "]\n" else "],\n");
        }
        try w.writeAll("  ],\n");

        try w.print("  \"max_color\": {d}\n", .{@as(i32, @intCast(self.aod_slots_per_color.len)) - 1});
        try w.writeAll("}");

        return allocator.dupe(u8, buf.written());
    }

    pub fn writeToFile(self: *const Logical, allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !void {
        const json = try self.toJson(allocator);
        defer allocator.free(json);

        const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
        defer file.close(io);
        try file.writePositionalAll(io, json, 0);
    }
};
