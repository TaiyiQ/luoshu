//! Regenerates every golden snapshot in testdata/: the route-level Sequence
//! snapshots (graph -> route.computeSequence -> JSON) and the metrics golden
//! (one line of bench numbers per circuit).
//!
//! Run via `zig build update-snapshots`, then review the diff with git.
const std = @import("std");
const arch = @import("arch");
const route = @import("route");
const serialize = @import("serialize");
const golden = @import("golden");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // The graph snapshot cases live in route.zig, shared with its tests.
    for (route.snapshot_cases) |case| {
        const json = try route.snapshotJson(gpa, case.kind);
        defer gpa.free(json);

        try serialize.writeJsonFile(io, case.path, json);
        std.debug.print("wrote {s}\n", .{case.path});
    }

    const cfg = try arch.load(gpa, io, golden.arch_path);
    defer cfg.deinit(gpa);

    // metricsJson runs every case through runCase, which verifies the
    // schedule and checks CZ coverage, so an illegal or lossy schedule can
    // never be blessed as a baseline.
    const json = try golden.metricsJson(gpa, cfg);
    defer gpa.free(json);
    try serialize.writeJsonFile(io, golden.metrics_path, json);
    std.debug.print("wrote {s}\n", .{golden.metrics_path});
}
