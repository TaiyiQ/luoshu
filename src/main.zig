const std = @import("std");
const toml = @import("toml");
const arch = @import("arch");
const route = @import("route");
const core = @import("graph");
const schedule = @import("schedule");
const viz = @import("viz");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    var parser = toml.Parser(arch.RawArchConfig).init(arenaAlloc);
    defer parser.deinit();

    var raw = try parser.parseFile(init.io, "./example/arch.toml");
    defer raw.deinit();

    const cfg = try arch.convertConfig(raw.value, arenaAlloc);
    cfg.print();

    // MVP
    //    var g = try core.Graph.init(alloc, 7, false);
    //    defer g.deinit();
    //    try g.addEdge(0, 1);
    //    try g.addEdge(0, 5);
    //    try g.addEdge(1, 6);
    //    try g.addEdge(5, 6);
    //    try g.addEdge(6, 3);
    //    try g.addEdge(6, 4);
    //    try g.addEdge(3, 4);
    //    try g.addEdge(3, 2);
    //    try g.addEdge(4, 2);

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
    var g = try core.Graph.init(alloc, 8, false);
    defer g.deinit();
    try g.addEdge(0, 4);
    try g.addEdge(0, 2);
    try g.addEdge(4, 6);
    try g.addEdge(0, 1);
    try g.addEdge(2, 3);
    try g.addEdge(4, 5);
    try g.addEdge(6, 7);

    var logical = try route.compile(alloc, &g);
    defer logical.deinit(alloc);
    logical.print();

    var physical = try schedule.physicalSchedule(init.arena.allocator(), cfg, logical);
    defer physical.deinit();
    try viz.showSlideshow(alloc, cfg, physical);
    //try physical.dumpSlideshow(alloc, init.io, "./zig-out/slideshow");
    //    try physical.dumpSvg(alloc, init.io, "./zig-out/placement.svg");

    //    const io = init.io;
    //    try schedule.writeToFile(alloc, io, &s, "./testdata/test.json");

    std.debug.print(">> Gate compilation completed\n", .{});
}
