const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const circuit = @import("circuit");
const compiler = @import("compiler");
const draw = @import("draw");
const serialize = @import("serialize");
const trace = @import("trace");
const verify = @import("verify");

const usage =
    \\usage: gatecomp <circuit.qasm> [options]
    \\
    \\options:
    \\  --arch <file>       architecture TOML (default: ./arch.toml)
    \\  --emit-json <path>  write the hardware schedule as JSON
    \\  --draw              open the schedule visualization (default: true)
    \\  -v, --verbose       trace the compiler passes to stderr
    \\  -h, --help          show this help
    \\
;

const Options = struct {
    qasm_path: []const u8,
    arch_path: []const u8 = "arch.toml",
    emit_json: ?[]const u8 = null,
    draw: bool = true,
    verbose: bool = false,
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("gatecomp: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Parses argv into Options. String values are duped into `arena` because
/// the iterator's slices don't outlive it.
fn parseArgs(arena: std.mem.Allocator, args: std.process.Args) !Options {
    var it = try std.process.Args.Iterator.initAllocator(args, arena);
    defer it.deinit();
    _ = it.next(); // argv[0]

    var qasm_path: ?[]const u8 = null;
    var opts = Options{ .qasm_path = undefined };

    while (it.next()) |argument| {
        const arg = std.mem.sliceTo(argument, 0);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(usage, .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--arch")) {
            const v = it.next() orelse fatal("--arch expects a file", .{});
            opts.arch_path = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--emit-json")) {
            const v = it.next() orelse fatal("--emit-json expects a path", .{});
            opts.emit_json = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--draw")) {
            opts.draw = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fatal("unknown option '{s}'\n\n" ++ usage, .{arg});
        } else if (qasm_path == null) {
            qasm_path = try arena.dupe(u8, arg);
        } else {
            fatal("unexpected argument '{s}'\n\n" ++ usage, .{arg});
        }
    }

    opts.qasm_path = qasm_path orelse fatal("missing <circuit.qasm>\n\n" ++ usage, .{});
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const opts = try parseArgs(init.arena.allocator(), init.minimal.args);
    trace.enabled = opts.verbose;

    var circ = circuit.load(init.gpa, init.io, opts.qasm_path) catch |err|
        fatal("cannot load circuit '{s}': {t}", .{ opts.qasm_path, err });
    defer circ.deinit();

    var pipeline = try circuit.decompose(init.gpa, circ);
    defer pipeline.deinit();

    const cfg = arch.load(init.gpa, init.io, opts.arch_path) catch |err|
        fatal("cannot load architecture '{s}': {t}", .{ opts.arch_path, err });
    defer cfg.deinit(init.gpa);
    if (opts.verbose) cfg.print();

    var sch = try compiler.compile(init.gpa, &pipeline, cfg);
    defer sch.deinit();
    //if (builtin.mode == .Debug) try verify.verify(init.gpa, &sch);

    if (opts.emit_json) |path| {
        try serialize.writeHardware(init.gpa, init.io, path, &sch);
    }

    if (opts.draw) {
        // Draw original circuit.
        try draw.pipeline(circ, null);
        // Draw circuit decomposed into stages.
        try draw.pipeline(circ, pipeline);
        // Draw arch layout and compiled schedule.
        try draw.physical(init.gpa, cfg, sch);
    }
}
