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

pub const PhysicalSchedule = struct {
    arena: std.heap.ArenaAllocator,
    ops: []const Op,
    placement: []Point, // Index corresponds to qubit id.
    slots: []const Point, // SLM trap sites in the entanglement zone.

    pub fn deinit(s: *PhysicalSchedule) void {
        s.arena.deinit();
    }
};

// Enumerate every SLM trap site in the entanglement zone. These are drawn
// as background indicators in the slideshow (grey ring = empty, green = occupied).
fn computeSlots(allocator: std.mem.Allocator, layout: arch.ArchConfig) ![]const Point {
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

    for (layout.entanglement_zone.slms) |slm| {
        const x0 = layout.entanglement_zone.offset_nm[0] + slm.offset_nm[0];
        const y0 = layout.entanglement_zone.offset_nm[1] + slm.offset_nm[1];
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

fn moveSlmQubits(
    allocator: std.mem.Allocator,
    cz: arch.EntanglementZone,
    slm_qubits: []const ?usize,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
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

    const op = Op{ .t = 0, .kind = .{
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

fn moveAodQubits(
    allocator: std.mem.Allocator,
    cz: arch.EntanglementZone,
    aod_qubits: [][]?usize,
    placement: *[]Point,
    ops: *std.ArrayList(Op),
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

        const op = Op{ .t = @as(u32, @intCast(t)) + 1, .kind = .{
            .move = .{
                .aod = 0,
                .translate = Axis.y,
                .src_zone = Zone.compute,
                .dest_zone = Zone.compute,
                .atoms = atoms.items,
            },
        } };

        try ops.append(allocator, op);
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

// NOTE: There is a relationship between the logical timesteps and the coloring steps.
// For example, we need to place the SLMs first (t0).
pub fn physicalSchedule(allocator: std.mem.Allocator, layout: arch.ArchConfig, logical: Schedule) !PhysicalSchedule {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var placement = try qubitPlacement(
        alloc,
        layout.storage_zone,
        logical.slm_slots,
        logical.aod_slots_per_color,
    );

    var ops: std.ArrayList(Op) = .empty;

    try moveSlmQubits(
        alloc,
        layout.entanglement_zone,
        logical.slm_slots,
        &placement,
        &ops,
    );

    try moveAodQubits(
        alloc,
        layout.entanglement_zone,
        logical.aod_slots_per_color,
        &placement,
        &ops,
    );

    return .{
        .arena = arena,
        .ops = ops.items,
        .placement = placement,
        .slots = try computeSlots(alloc, layout),
    };
}

pub const Schedule = struct {
    slm_slots: []const ?usize,
    aod_slots_per_color: [][]?usize,
    max_color: i32,

    pub fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
        allocator.free(self.slm_slots);
        for (self.aod_slots_per_color) |slot| allocator.free(slot);
        allocator.free(self.aod_slots_per_color);
    }

    pub fn print(self: Schedule) void {
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
};

pub fn toJson(allocator: std.mem.Allocator, schedule: *const Schedule) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");

    try w.writeAll("  \"slm_slots\": [");
    for (schedule.slm_slots, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
    }
    try w.writeAll("],\n");

    try w.writeAll("  \"aod_slots_per_color\": [\n");
    for (schedule.aod_slots_per_color, 0..) |row, ci| {
        try w.writeAll("    [");
        for (row, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
        }
        const last = ci == schedule.aod_slots_per_color.len - 1;
        try w.writeAll(if (last) "]\n" else "],\n");
    }
    try w.writeAll("  ],\n");

    try w.print("  \"max_color\": {d}\n", .{schedule.max_color});
    try w.writeAll("}");

    return allocator.dupe(u8, buf.written());
}

pub fn writeToFile(allocator: std.mem.Allocator, io: std.Io, schedule: *const Schedule, filename: []const u8) !void {
    const json = try toJson(allocator, schedule);
    defer allocator.free(json);

    const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    try file.writePositionalAll(io, json, 0);
}
