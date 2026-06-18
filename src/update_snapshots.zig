//! Regenerates every golden snapshot in testdata/: the route-level Sequence
//! snapshots (graph -> route.computeSequence -> JSON) and the circuit-level goldens
//! (circuit -> Sequence JSON per stage, and -> Hardware JSON).
//!
//! Run via `zig build update-snapshots`, then review the diff with git.
const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");
const compiler = @import("compiler");
const route = @import("route");
const serialize = @import("serialize");
const verify = @import("verify");
const golden = @import("golden");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // The graph snapshot cases live in route.zig, shared with its tests.
    for (route.snapshot_cases) |case| {
        var g = try route.buildSnapshotGraph(case.kind, gpa);
        defer g.deinit();

        var seq = try route.computeSequence(gpa, &g);
        defer seq.deinit();

        try serialize.writeSequence(gpa, io, case.path, seq.fixed, seq.moveable);
        std.debug.print("wrote {s}\n", .{case.path});
    }

    const cfg = try arch.load(gpa, io, golden.arch_path);
    defer cfg.deinit(gpa);

    for (golden.cases) |case| {
        var circ = try golden.buildCircuit(case.kind, gpa);
        defer circ.deinit();

        var pipe = try circuit.decompose(gpa, circ);
        defer pipe.deinit();

        const seq_json = try golden.sequencesJson(gpa, &pipe);
        defer gpa.free(seq_json);
        try serialize.writeJsonFile(io, case.sequence_path, seq_json);

        var hw = try compiler.compile(gpa, &pipe, cfg, null);
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
                    .{ @tagName(case.kind), expected },
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
