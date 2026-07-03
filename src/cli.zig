const std = @import("std");
const settings = @import("settings");

const usage =
    \\usage: gatecomp [circuit.qasm] [options]
    \\
    \\Compiles one circuit when <circuit.qasm> is given; without it, runs
    \\every circuit in the settings [benchmark] list (visualization off,
    \\per-circuit outputs under the benchmark out_dir).
    \\
    \\options:
    \\  --config <file>     settings TOML encoding these options
    \\                      (default: ./config/settings.toml, may be absent)
    \\  --arch <file>       architecture TOML (default: ./config/arch.toml)
    \\  --asm <file>        storage occupancy JSON from the upstream
    \\                      atom-rearrangement package; omitting it uses
    \\                      procedural placement
    \\  --out <path>        write the hardware schedule as JSON
    \\  --bench <path>      write schedule benchmark metrics as JSON
    \\  --no-draw           skip the schedule visualization
    \\  -v, --verbose       trace the compiler passes to stderr
    \\  -h, --help          show this help
    \\
;

pub const Options = struct {
    /// Circuits to compile: the single positional argument, or the settings
    /// [benchmark] list when none is given.
    circuits: []const []const u8,
    /// True when circuits came from the settings [benchmark] list: outputs
    /// derive from out_dir and the visualization is skipped.
    benchmark: bool = false,
    arch_path: []const u8 = "config/arch.toml",
    asm_path: ?[]const u8 = null,
    out: ?[]const u8 = null,
    bench: ?[]const u8 = null,
    /// Benchmark mode only: directory for <name>.hardware.json and
    /// <name>.bench.json per circuit; null skips writing.
    out_dir: ?[]const u8 = null,
    draw: bool = true,
    verbose: bool = false,
};

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("gatecomp: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Parses argv into Options, filling flags the command line leaves unset
/// from the settings TOML: command line beats settings beats built-in
/// defaults. String values are duped into `arena` because the iterator's
/// slices don't outlive it.
pub fn parseArgs(arena: std.mem.Allocator, io: std.Io, args: std.process.Args) !Options {
    var it = try std.process.Args.Iterator.initAllocator(args, arena);
    defer it.deinit();
    _ = it.next(); // argv[0]

    var qasm_path: ?[]const u8 = null;
    var settings_path: ?[]const u8 = null;
    var arch_path: ?[]const u8 = null;
    var asm_path: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var bench: ?[]const u8 = null;
    var no_draw = false;
    var verbose = false;

    while (it.next()) |argument| {
        const arg = std.mem.sliceTo(argument, 0);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(usage, .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--config")) {
            const v = it.next() orelse fatal("--config expects a file", .{});
            settings_path = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--arch")) {
            const v = it.next() orelse fatal("--arch expects a file", .{});
            arch_path = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--asm")) {
            const v = it.next() orelse fatal("--asm expects a file", .{});
            asm_path = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--out")) {
            const v = it.next() orelse fatal("--out expects a path", .{});
            out = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--bench")) {
            const v = it.next() orelse fatal("--bench expects a path", .{});
            bench = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--no-draw")) {
            no_draw = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fatal("unknown option '{s}'\n\n" ++ usage, .{arg});
        } else if (qasm_path == null) {
            qasm_path = try arena.dupe(u8, arg);
        } else {
            fatal("unexpected argument '{s}'\n\n" ++ usage, .{arg});
        }
    }

    // An explicit --config file must exist; the default may be absent.
    const cfg: settings.Settings = if (settings_path) |p|
        settings.load(arena, io, p) catch |err|
            fatal("cannot load settings '{s}': {t}", .{ p, err })
    else
        settings.load(arena, io, settings.default_path) catch |err| switch (err) {
            error.FileNotFound => .{},
            else => fatal("cannot load settings '{s}': {t}", .{ settings.default_path, err }),
        };

    var opts = Options{
        .circuits = undefined,
        .arch_path = arch_path orelse cfg.options.arch orelse "config/arch.toml",
        .asm_path = asm_path orelse cfg.options.assembly,
        .out = out orelse cfg.options.out,
        .bench = bench orelse cfg.options.bench,
        .out_dir = cfg.benchmark.out_dir,
        .draw = if (no_draw) false else cfg.options.draw orelse true,
        .verbose = verbose or (cfg.options.verbose orelse false),
    };

    if (qasm_path) |p| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = p;
        opts.circuits = one;
    } else if (cfg.benchmark.circuits.len > 0) {
        opts.circuits = cfg.benchmark.circuits;
        opts.benchmark = true;
        opts.draw = false; // batch run: metrics, not windows
    } else {
        fatal("missing <circuit.qasm> and no [benchmark] circuits in settings\n\n" ++ usage, .{});
    }
    return opts;
}
