const std = @import("std");
const toml = @import("toml");
const arch = @import("arch");
const circuit = @import("circuit");
const route = @import("route");
const core = @import("graph");
const schedule = @import("schedule");
const viz = @import("viz");

fn circuitGraph(allocator: std.mem.Allocator, c: circuit.Circuit) !core.Graph {
    var g = try core.Graph.init(allocator, c.n, false);

    for (c.gates.items) |gate| {
        if (gate == .cz) {
            try g.addEdge(gate.cz.control, gate.cz.target);
        }
    }

    return g;
}

fn loadArch(allocator: std.mem.Allocator, io: std.Io) !arch.ArchConfig {
    var parser = toml.Parser(arch.RawArchConfig).init(allocator);
    defer parser.deinit();

    var raw = try parser.parseFile(io, "./example/arch.toml");
    defer raw.deinit();

    return try arch.convertConfig(raw.value, allocator);
}

fn loadCircuit(allocator: std.mem.Allocator, io: std.Io) !circuit.Circuit {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, "./example/mvp.qasm", .{ .mode = .read_only });
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    const reader = &fr.interface;

    // Reads everything to EOF into allocator-owned memory. No truncation,
    // no "must fill exactly N bytes" error.
    const src = try reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(src);

    var parser = circuit.QasmParser.init(allocator, src);
    const circ = try parser.parse();

    return circ;
}

pub fn main(init: std.process.Init) !void {
    var c = try loadCircuit(init.gpa, init.io);
    defer c.deinit();

    var stages = try circuit.decompose(init.gpa, c);
    defer circuit.freeStages(init.gpa, &stages);
    try circuit.draw(c, stages);

    var g = try circuitGraph(init.gpa, c);
    defer g.deinit();

    var logical = try route.compile(init.gpa, &g);
    defer logical.deinit();
    try logical.writeToFile(init.gpa, init.io, "./zig-out/logical.json");
    logical.print();

    const cfg = try loadArch(init.gpa, init.io);
    defer cfg.deinit(init.gpa);

    var physical = try schedule.physical(init.gpa, cfg, logical);
    defer physical.deinit();
    try physical.writeToFile(init.gpa, init.io, "./zig-out/physical.json");

    try viz.simulate(init.gpa, cfg, physical);

    std.debug.print(">> Gate compilation completed\n", .{});
}

//    var c = circuit.Circuit.init(init.gpa, 7);
//    defer c.deinit();
//    try c.cz(0, 1);
//    try c.cz(0, 5);
//    try c.cz(1, 6);
//    try c.cz(5, 6);
//    try c.cz(6, 3);
//    try c.cz(6, 4);
//    try c.cz(3, 4);
//    try c.cz(3, 2);
//    try c.cz(4, 2);

//    var c = circuit.Circuit.init(init.gpa, 4);
//    defer c.deinit();
//    try c.h(0);
//    try c.cx(0, 1);
//    try c.rz(2, 1.57);
//    try c.z(3);
//    try c.u(0, 0.1, 0.2, 0.3);

//    // MVP
//    var g = try core.Graph.init(init.gpa, 7, false);
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
