//! Regenerates every golden snapshot in testdata/: the route-level Sequence
//! snapshots (graph -> route.computeSequence -> JSON), the metrics golden
//! (one line of bench numbers per circuit), and the two byte-pinned
//! Hardware JSON files that pin the serialization format.
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

    // runCase verifies the schedule and checks CZ coverage, so an illegal
    // or lossy schedule can never be blessed as a baseline.
    for (golden.cases) |case| {
        const path = case.hardware_path orelse continue;
        const res = try golden.runCase(gpa, cfg, case.kind);
        defer gpa.free(res.hw_json);

        try serialize.writeJsonFile(io, path, res.hw_json);
        std.debug.print("wrote {s}\n", .{path});
    }

    const json = try golden.metricsJson(gpa, cfg);
    defer gpa.free(json);
    try serialize.writeJsonFile(io, golden.metrics_path, json);
    std.debug.print("wrote {s}\n", .{golden.metrics_path});
}
