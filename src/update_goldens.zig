//! Regenerates the metrics golden (testdata/metrics.json): one line of
//! bench numbers per circuit.
//!
//! Run via `zig build update-goldens`, then review the diff with git.
const std = @import("std");
const arch = @import("arch");
const serialize = @import("serialize");
const golden = @import("golden");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cfg = try arch.load(gpa, io, golden.arch_path);
    defer cfg.deinit(gpa);

    // metricsJson runs every case through runCase, which verifies the
    // schedule and checks CZ coverage, so an illegal or lossy schedule can
    // never be blessed as a baseline.
    const json = try golden.metricsJson(gpa, io, cfg);
    defer gpa.free(json);

    try serialize.writeJsonFile(io, golden.metrics_path, json);

    std.debug.print("wrote {s}\n", .{golden.metrics_path});
}
