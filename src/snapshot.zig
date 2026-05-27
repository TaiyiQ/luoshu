const std = @import("std");
const route = @import("route");

const Graph = route.Graph;
const Schedule = route.Schedule;
const compile = route.compile;

pub const GraphBuilder = *const fn (std.mem.Allocator) anyerror!Graph;

/// Serialises a Schedule to an owned JSON string.
/// Uses ArrayList so it works in tests (no std.Io needed).
pub fn scheduleToJson(allocator: std.mem.Allocator, schedule: *const Schedule) ![]u8 {
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

    try w.print("  \"max_color\": {d}\n", .{@as(i32, @intCast(schedule.aod_slots_per_color.len)) - 1});
    try w.writeAll("}");

    return allocator.dupe(u8, buf.written());
}

/// Runs compile() on the graph produced by `build`, serialises the
/// result, and compares it byte-for-byte against `snapshot_path`.
/// Fails with a clear diff-style print if they diverge.
pub fn snapshotTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    build: GraphBuilder,
    snapshot_path: []const u8,
) !void {
    var g = try build(allocator);
    defer g.deinit();

    var schedule = try compile(allocator, &g);
    defer schedule.deinit(allocator);

    const actual = try scheduleToJson(allocator, &schedule);
    defer allocator.free(actual);

    const file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                "\nSnapshot missing: {s}\n" ++
                    "  Run `zig build update-snapshots` to generate it.\n",
                .{snapshot_path},
            );
        }
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const expected = try allocator.alloc(u8, stat.size);
    defer allocator.free(expected);
    _ = try file.readPositionalAll(io, expected, 0);

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print(
            "\nSnapshot mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
            .{ snapshot_path, expected, actual },
        );
        return error.SnapshotMismatch;
    }
}
