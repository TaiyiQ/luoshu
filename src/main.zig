const std = @import("std");
const toml = @import("toml");
const arch = @import("arch");
const route = @import("route");
const core = @import("graph");
const schedule = @import("schedule");
const viz = @import("viz");

pub fn main(init: std.process.Init) !void {
    var parser = toml.Parser(arch.RawArchConfig).init(init.gpa);
    defer parser.deinit();

    var raw = try parser.parseFile(init.io, "./example/arch.toml");
    defer raw.deinit();

    const cfg = try arch.convertConfig(raw.value, init.gpa);
    defer cfg.deinit(init.gpa);
    //cfg.print();

    // MVP
    var g = try core.Graph.init(init.gpa, 7, false);
    defer g.deinit();
    try g.addEdge(0, 1);
    try g.addEdge(0, 5);
    try g.addEdge(1, 6);
    try g.addEdge(5, 6);
    try g.addEdge(6, 3);
    try g.addEdge(6, 4);
    try g.addEdge(3, 4);
    try g.addEdge(3, 2);
    try g.addEdge(4, 2);

    // QFT
    //    var g = try core.Graph.init(alloc, 5, false);
    //    defer g.deinit();
    //    try g.addEdge(0, 1);
    //    try g.addEdge(0, 2);
    //    try g.addEdge(0, 3);
    //    try g.addEdge(0, 4);
    //    try g.addEdge(1, 2);
    //    try g.addEdge(1, 3);
    //    try g.addEdge(1, 4);
    //    try g.addEdge(2, 3);
    //    try g.addEdge(2, 4);
    //    try g.addEdge(3, 4);

    // QHZ
    //    var g = try core.Graph.init(alloc, 8, false);
    //    defer g.deinit();
    //    try g.addEdge(0, 4);
    //    try g.addEdge(0, 2);
    //    try g.addEdge(4, 6);
    //    try g.addEdge(0, 1);
    //    try g.addEdge(2, 3);
    //    try g.addEdge(4, 5);
    //    try g.addEdge(6, 7);

    // Cycle
    //    var g = try core.Graph.init(alloc, 6, false);
    //    defer g.deinit();
    //    try g.addEdge(0, 1);
    //    try g.addEdge(1, 2);
    //    try g.addEdge(2, 3);
    //    try g.addEdge(3, 4);
    //    try g.addEdge(4, 5);
    //    try g.addEdge(5, 0);

    // Ladder
    //    var g = try core.Graph.init(alloc, 8, false);
    //    defer g.deinit();
    //    try g.addEdge(0, 1);
    //    try g.addEdge(1, 2);
    //    try g.addEdge(2, 3);
    //    try g.addEdge(4, 5);
    //    try g.addEdge(5, 6);
    //    try g.addEdge(6, 7);
    //    try g.addEdge(0, 4);
    //    try g.addEdge(1, 5);
    //    try g.addEdge(2, 6);
    //    try g.addEdge(3, 7);

    var logical = try route.compile(init.gpa, &g);
    defer logical.deinit();
    //try logical.writeToFile(alloc, init.io, "./zig-out/logical.json");
    //logical.print();

    var physical = try schedule.physical(init.gpa, cfg, logical);
    defer physical.deinit();
    //try physical.writeToFile(alloc, init.io, "./zig-out/physical.json");

    try viz.simulate(init.gpa, cfg, physical);

    std.debug.print(">> Gate compilation completed\n", .{});
}
