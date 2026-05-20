const std = @import("std");
const toml = @import("toml");
const arch = @import("arch.zig");
const route = @import("route.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    var parser = toml.Parser(arch.RawArchConfig).init(arenaAlloc);
    defer parser.deinit();

    var raw = try parser.parseFile(init.io, "./arch.toml");
    defer raw.deinit();

    const cfg = try arch.convertConfig(raw.value, arenaAlloc);
    cfg.print();

    var g = try route.Graph.init(alloc, 7, false);
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

    var schedule = try route.compile(alloc, &g);
    defer schedule.deinit(alloc);
    schedule.print();

    const io = init.io;
    try route.writeToJson(alloc, io, &schedule, "testdata/test.json");

    std.debug.print(">> Gate compilation completed\n", .{});
}
