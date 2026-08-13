//! Regenerates every golden snapshot in testdata/: the route-level Sequence
//! snapshots (graph -> route.computeSequence -> JSON) and the circuit-level goldens
//! (circuit -> Sequence JSON per stage, and -> Hardware JSON).
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

    // caseJson runs the verifier, so an illegal schedule can never be
    // blessed as a golden baseline.
    for (golden.cases) |case| {
        const json = try golden.caseJson(gpa, cfg, case);
        defer gpa.free(json.seq);
        defer gpa.free(json.hw);

        try serialize.writeJsonFile(io, case.sequence_path, json.seq);
        try serialize.writeJsonFile(io, case.hardware_path, json.hw);
        std.debug.print("wrote {s}\nwrote {s}\n", .{ case.sequence_path, case.hardware_path });
    }
}
