const std = @import("std");
const arch = @import("arch");

const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

const Point = struct { x: i32, y: i32 };
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

const Op = struct {
    t: u32,
    kind: OpKind,
};

const PhysicalSchedule = struct {
    arena: std.heap.ArenaAllocator,
    ops: []const Op,
    placement: []Point, // Index corresponds to qubit id.

    pub fn deinit(s: *PhysicalSchedule) void {
        s.arena.deinit();
    }
};

pub fn physicalSchedule(allocator: std.mem.Allocator, layout: arch.ArchConfig, logical: Schedule) !PhysicalSchedule {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // FIXME: Update the qubit count.
    const max_qubit = layout.storage_zone.slm.num_col * layout.storage_zone.slm.num_row;
    const placement = try a.alloc(Point, max_qubit);

    try storagePlacement(layout, placement);

    std.debug.print("{}: {any}\n", .{ logical.max_color, placement });

    const ops = try a.alloc(Op, 1);

    return .{
        .arena = arena,
        .ops = ops,
        .placement = placement,
    };
}

pub fn storagePlacement(layout: arch.ArchConfig, placement: []Point) !void {
    const zone = layout.storage_zone;
    const slm = layout.storage_zone.slm;

    // Relative starting origin of grid (bottom-left).
    const x_orig = zone.offset_nm[0] + slm.offset_nm[0];
    const y_orig = zone.offset_nm[1] + slm.offset_nm[1];

    // Seperation spacing between grid items.
    const x_sep = @as(i32, @intCast(slm.sep_nm[0]));
    const y_sep = @as(i32, @intCast(slm.sep_nm[1]));

    var qubit_id: u32 = 0;

    for (0..slm.num_row) |i| {
        for (0..slm.num_col) |j| {
            const x = x_orig + @as(i32, @intCast(j)) * x_sep;
            const y = y_orig + @as(i32, @intCast(i)) * y_sep;
            placement[qubit_id] = Point{ .x = x, .y = y };
            qubit_id += 1;
        }
    }
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
