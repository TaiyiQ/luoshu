const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");
const route = @import("route");
const schedule = @import("schedule");
const draw = @import("draw");
const serialize = @import("serialize");

pub fn main(init: std.process.Init) !void {
    var circ = try circuit.load(init.gpa, init.io, "../qasm/mvp.qasm");
    //var circ = try circuit.load(init.gpa, init.io, "../qasm/ghz-test.qasm");
    //var circ = try circuit.load(init.gpa, init.io, "../qasm/mvp-v2.qasm");
    defer circ.deinit();

    var pipeline = try circuit.decompose(init.gpa, circ);
    defer pipeline.deinit();

    const cfg = try arch.load(init.gpa, init.io, "./example/arch.toml");
    defer cfg.deinit(init.gpa);

    var sch = try pipeline.compile(cfg);
    defer sch.deinit();
    //try serialize.writeHardware(init.gpa, init.io, "./zig-out/physical.json", &sch);

    //try draw.pipeline(circ, null); // Draw original circuit.
    //try draw.pipeline(circ, pipeline);
    //try draw.stageGraph(circ, pipeline);
    try draw.physical(init.gpa, cfg, sch);
}
