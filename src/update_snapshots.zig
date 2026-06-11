//! Regenerates every golden snapshot in testdata/: the route-level Sequence
//! snapshots (graph -> route.compile -> JSON) and the circuit-level goldens
//! (circuit -> Sequence JSON per stage, and -> Hardware JSON).
//!
//! Run via `zig build update-snapshots`, then review the diff with git.
const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");
const route = @import("route");
const serialize = @import("serialize");
const verify = @import("verify");
const golden = @import("golden");

const GraphCase = struct {
    build: *const fn (std.mem.Allocator) anyerror!route.Graph,
    path: []const u8,
};

// Must mirror the snapshot tests in route.zig.
const graph_cases = [_]GraphCase{
    .{ .build = route.buildMvpGraph, .path = "testdata/mvp.json" },
    .{ .build = route.buildCycleGraph, .path = "testdata/cycle.json" },
    .{ .build = route.buildLadderGraph, .path = "testdata/ladder.json" },
    .{ .build = route.buildGridGraph, .path = "testdata/grid.json" },
    .{ .build = route.buildGhzGraph, .path = "testdata/ghz.json" },
    .{ .build = route.buildQftGraph, .path = "testdata/qft.json" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    for (graph_cases) |case| {
        var g = try case.build(gpa);
        defer g.deinit();

        var seq = try route.compile(gpa, &g);
        defer seq.deinit();

        try serialize.writeSequence(gpa, io, case.path, seq.fixed, seq.moveable);
        std.debug.print("wrote {s}\n", .{case.path});
    }

    const cfg = try arch.load(gpa, io, golden.arch_path);
    defer cfg.deinit(gpa);

    for (golden.cases) |case| {
        var circ = try case.build(gpa);
        defer circ.deinit();

        var pipe = try circuit.decompose(gpa, circ);
        defer pipe.deinit();

        const seq_json = try golden.sequencesJson(gpa, &pipe);
        defer gpa.free(seq_json);
        try serialize.writeJsonFile(io, case.sequence_path, seq_json);

        var hw = try pipe.compile(cfg);
        defer hw.deinit();

        // Never snapshot an illegal schedule as a golden baseline — except
        // a documented known violation, which is asserted so a routing fix
        // is noticed here too.
        if (case.known_violation) |expected| {
            verify.quiet = true;
            defer verify.quiet = false;
            if (verify.verify(gpa, &hw)) |_| {
                std.debug.print(
                    "{s}: known violation {t} no longer occurs — clear known_violation and rerun\n",
                    .{ case.name, expected },
                );
                return error.KnownViolationFixed;
            } else |err| if (err != expected) return err;
        } else {
            try verify.verify(gpa, &hw);
        }

        const hw_json = try serialize.hardwareToJson(gpa, &hw);
        defer gpa.free(hw_json);
        try serialize.writeJsonFile(io, case.hardware_path, hw_json);

        std.debug.print("wrote {s}\nwrote {s}\n", .{ case.sequence_path, case.hardware_path });
    }
}
