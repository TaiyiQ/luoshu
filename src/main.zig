const std = @import("std");
const toml = @import("toml");
const arch = @import("arch");
const circuit = @import("circuit");
const route = @import("route");
const schedule = @import("schedule");
const draw = @import("draw");

pub fn main(init: std.process.Init) !void {
    var circ = try loadCircuit(init.gpa, init.io);
    defer circ.deinit();

    var pipeline = try circuit.decompose(init.gpa, circ);
    defer pipeline.deinit();

    const cfg = try loadArch(init.gpa, init.io);
    defer cfg.deinit(init.gpa);

    var sch = try pipeline.compile(cfg);
    defer sch.deinit();
    //try sched.writeToFile(init.gpa, init.io, "./zig-out/physical.json");

    //try draw.pipeline(circ, null); // Draw original circuit.
    //try draw.pipeline(circ, pipeline);
    //try draw.stageGraph(circ, pipeline);
    try draw.physical(init.gpa, cfg, sch);

    std.debug.print(">> Gate compilation completed\n", .{});
}

fn loadCircuit(allocator: std.mem.Allocator, io: std.Io) !circuit.Circuit {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, "./example/mvp.qasm", .{ .mode = .read_only });
    //const file = try cwd.openFile(io, "./example/ghz-test.qasm", .{ .mode = .read_only });
    //const file = try cwd.openFile(io, "./example/mvp-v2.qasm", .{ .mode = .read_only });
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

fn loadArch(allocator: std.mem.Allocator, io: std.Io) !arch.ArchConfig {
    var parser = toml.Parser(arch.RawArchConfig).init(allocator);
    defer parser.deinit();

    var raw = try parser.parseFile(io, "./example/arch.toml");
    defer raw.deinit();

    return try arch.convertConfig(raw.value, allocator);
}
