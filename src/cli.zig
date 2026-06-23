const std = @import("std");

const usage =
    \\usage: gatecomp <circuit.qasm> [options]
    \\
    \\options:
    \\  --arch <file>       architecture TOML (default: ./arch.toml)
    \\  --asm <file>        storage occupancy JSON from the upstream
    \\                      atom-rearrangement package
    \\                      (default: ./example/assembly.json)
    \\  --out <path>     write the hardware schedule as JSON
    \\  --bench <path>      write schedule benchmark metrics as JSON
    \\  --draw / --no-draw  open the schedule visualization (default: on)
    \\  -v, --verbose       trace the compiler passes to stderr
    \\  -h, --help          show this help
    \\
;

const Options = struct {
    qasm_path: []const u8,
    arch_path: []const u8 = "arch.toml",
    asm_path: ?[]const u8 = "./example/assembly.json",
    out: ?[]const u8 = null,
    bench: ?[]const u8 = null,
    draw: bool = true,
    verbose: bool = false,
};

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("gatecomp: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Parses argv into Options. String values are duped into `arena` because
/// the iterator's slices don't outlive it.
pub fn parseArgs(arena: std.mem.Allocator, args: std.process.Args) !Options {
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
        } else if (std.mem.eql(u8, arg, "--asm")) {
            const v = it.next() orelse fatal("--asm expects a file", .{});
            opts.asm_path = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--out")) {
            const v = it.next() orelse fatal("--out expects a path", .{});
            opts.out = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--bench")) {
            const v = it.next() orelse fatal("--bench expects a path", .{});
            opts.bench = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--draw")) {
            opts.draw = true;
        } else if (std.mem.eql(u8, arg, "--no-draw")) {
            opts.draw = false;
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
