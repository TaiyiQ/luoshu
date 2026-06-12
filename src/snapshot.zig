const std = @import("std");
// This file is only ever reached via route.zig's tests, so it compiles as
// part of the route module: route.zig is imported by file path (a module
// cannot name-import itself), serialize via the route module's imports.
const route = @import("route.zig");
const serialize = @import("serialize");

/// Runs computeSequence() on the graph produced by `case.build`, serialises
/// the result, and compares it byte-for-byte against `case.path`.
/// Fails with a clear diff-style print if they diverge.
pub fn snapshotTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    case: route.SnapshotCase,
) !void {
    var g = try case.build(allocator);
    defer g.deinit();

    var sequence = try route.computeSequence(allocator, &g);
    defer sequence.deinit();

    const actual = try serialize.sequenceToJson(allocator, sequence.fixed, sequence.moveable);
    defer allocator.free(actual);

    const file = std.Io.Dir.cwd().openFile(io, case.path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                "\nSnapshot missing: {s}\n" ++
                    "  Run `zig build update-snapshots` to generate it.\n",
                .{case.path},
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
            .{ case.path, expected, actual },
        );
        return error.SnapshotMismatch;
    }
}
