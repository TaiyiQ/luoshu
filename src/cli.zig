const std = @import("std");
const settings = @import("settings");

const usage =
    \\usage: gatecomp <circuit.qasm>... [options]
    \\
    \\Compiles each circuit given. Several circuits run as a suite: a
    \\metrics table prints per circuit, the visualizer stays closed, and
    \\outputs land under out_dir when it is set.
    \\
    \\options:
    \\  --config <file>     settings TOML encoding these options
    \\                      (default: cfg/settings.toml, may be absent)
    \\  --arch <file>       architecture TOML (default: cfg/arch.toml)
    \\  --asm <file>        storage occupancy JSON from the upstream
    \\                      atom-rearrangement package; omitting it uses
    \\                      procedural placement
    \\  --out <path>        write the hardware schedule as JSON
    \\                      (single circuit runs only)
    \\  --bench <path>      write schedule benchmark metrics as JSON
    \\                      (single circuit runs only)
    \\  --out-dir <dir>     directory for per-circuit outputs in a suite
    \\                      run: <name>.hardware.json and <name>.bench.json
    \\  --viz               open the schedule visualizer (off by default)
    \\  -v, --verbose       trace the compiler passes to stderr
    \\  -h, --help          show this help
    \\
;

/// One compilation: a circuit and where its outputs go (null skips writing).
pub const Job = struct {
    qasm: []const u8,
    out: ?[]const u8 = null,
    bench: ?[]const u8 = null,
};

pub const Options = struct {
    /// Compilations to run, one per positional circuit argument.
    jobs: []const Job,

    /// Layered run settings: flags over the config TOML over built-in
    /// defaults. Jobs already carry the out/bench paths derived from it.
    settings: settings.Resolved,
};

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("gatecomp: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Parses argv into Options. Flags collect into a settings.Options partial
/// that settings.resolve layers over the config TOML and built-in defaults.
/// String values are duped into `arena` because the iterator's slices don't
/// outlive it.
pub fn parseArgs(arena: std.mem.Allocator, io: std.Io, args: std.process.Args) !Options {
    var it = try std.process.Args.Iterator.initAllocator(args, arena);
    defer it.deinit();

    _ = it.next(); // argv[0]

    var circuits: std.ArrayList([]const u8) = .empty;
    var config_path: ?[]const u8 = null;
    var flags = settings.Options{};

    while (it.next()) |argument| {
        const arg = std.mem.sliceTo(argument, 0);

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(usage, .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--config")) {
            const v = it.next() orelse fatal("--config expects a file", .{});
            config_path = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--arch")) {
            const v = it.next() orelse fatal("--arch expects a file", .{});
            flags.arch = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--asm")) {
            const v = it.next() orelse fatal("--asm expects a file", .{});
            flags.assembly = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--out")) {
            const v = it.next() orelse fatal("--out expects a path", .{});
            flags.out = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--bench")) {
            const v = it.next() orelse fatal("--bench expects a path", .{});
            flags.bench = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            const v = it.next() orelse fatal("--out-dir expects a directory", .{});
            flags.out_dir = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--viz")) {
            flags.viz = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            flags.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fatal("unknown option '{s}'\n\n" ++ usage, .{arg});
        } else {
            try circuits.append(arena, try arena.dupe(u8, arg));
        }
    }

    const cfg = settings.resolve(arena, io, flags, config_path) catch |err|
        fatal("cannot load config '{s}': {t}", .{
            config_path orelse settings.default_path,
            err,
        });

    if (circuits.items.len == 0)
        fatal("missing <circuit.qasm>\n\n" ++ usage, .{});

    const jobs = try arena.alloc(Job, circuits.items.len);

    if (circuits.items.len == 1) {
        jobs[0] = .{
            .qasm = circuits.items[0],
            .out = cfg.out,
            .bench = cfg.bench,
        };

        return .{
            .jobs = jobs,
            .settings = cfg,
        };
    }

    // Suite run: out/bench name a single output file, whatever their source.
    if (cfg.out != null or cfg.bench != null)
        fatal("out/bench apply to a single circuit; suites use out_dir", .{});

    for (circuits.items, jobs) |qasm, *job| {
        job.* = .{ .qasm = qasm };

        if (cfg.out_dir) |dir| {
            const stem = std.fs.path.stem(qasm);
            job.out = try std.fmt.allocPrint(arena, "{s}/{s}.hardware.json", .{ dir, stem });
            job.bench = try std.fmt.allocPrint(arena, "{s}/{s}.bench.json", .{ dir, stem });
        }
    }

    return .{
        .jobs = jobs,
        .settings = cfg,
    };
}

test {
    std.testing.refAllDecls(@This());
}
