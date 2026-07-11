//! Run settings loaded from a TOML file (default: cfg/settings.toml).
//! The file encodes the CLI arguments so a bare `gatecomp` invocation is
//! reproducible. `resolve` layers the three sources: command-line flags
//! beat file values beat the built-in defaults on `Resolved`.

const std = @import("std");
const toml = @import("toml");

pub const default_path = "cfg/settings.toml";

/// Mirrors the [options] table: one key per CLI flag. Null means "not
/// set", leaving the value to the layer below. The CLI hands its parsed
/// flags to `resolve` in this shape too.
pub const Options = struct {
    arch: ?[]const u8 = null,
    assembly: ?[]const u8 = null,
    out: ?[]const u8 = null,
    bench: ?[]const u8 = null,
    viz: ?bool = null,
    verbose: ?bool = null,
};

/// Mirrors the [benchmark] table: circuits compiled when no <circuit.qasm>
/// is named on the command line, plus where their outputs land.
pub const Benchmark = struct {
    out_dir: ?[]const u8 = null,
    circuits: []const []const u8 = &.{},
};

pub const Settings = struct {
    options: Options = .{},
    benchmark: Benchmark = .{},
};

/// Options with every layer applied. The field defaults are the built-in
/// layer: what a bare run uses when neither the settings file nor the
/// command line has an opinion.
pub const Resolved = struct {
    arch: []const u8 = "cfg/arch.toml",
    assembly: ?[]const u8 = null,
    out: ?[]const u8 = null,
    bench: ?[]const u8 = null,
    viz: bool = false,
    verbose: bool = false,
    benchmark: Benchmark = .{},
};

/// Loads the settings file and layers `flags` on top. An explicit `path`
/// must exist; the default file may be absent.
pub fn resolve(arena: std.mem.Allocator, io: std.Io, flags: Options, path: ?[]const u8) !Resolved {
    const cfg: Settings = if (path) |p|
        try load(arena, io, p)
    else
        load(arena, io, default_path) catch |err| switch (err) {
            error.FileNotFound => .{},
            else => return err,
        };
    return merge(cfg, flags);
}

fn merge(cfg: Settings, flags: Options) Resolved {
    var r = Resolved{ .benchmark = cfg.benchmark };
    apply(&r, cfg.options);
    apply(&r, flags);
    return r;
}

fn apply(r: *Resolved, o: Options) void {
    if (o.arch) |v| r.arch = v;
    if (o.assembly) |v| r.assembly = v;
    if (o.out) |v| r.out = v;
    if (o.bench) |v| r.bench = v;
    if (o.viz) |v| r.viz = v;
    if (o.verbose) |v| r.verbose = v;
}

/// Parses a settings TOML file. Strings are duped into `arena` because the
/// parser frees its own storage when it goes out of scope here.
pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Settings {
    var parser = toml.Parser(Settings).init(arena);
    defer parser.deinit();

    var raw = try parser.parseFile(io, path);
    defer raw.deinit();

    return dupe(arena, raw.value);
}

fn dupe(arena: std.mem.Allocator, s: Settings) !Settings {
    var out = s;
    if (s.options.arch) |v| out.options.arch = try arena.dupe(u8, v);
    if (s.options.assembly) |v| out.options.assembly = try arena.dupe(u8, v);
    if (s.options.out) |v| out.options.out = try arena.dupe(u8, v);
    if (s.options.bench) |v| out.options.bench = try arena.dupe(u8, v);
    if (s.benchmark.out_dir) |v| out.benchmark.out_dir = try arena.dupe(u8, v);

    const circuits = try arena.alloc([]const u8, s.benchmark.circuits.len);
    for (s.benchmark.circuits, circuits) |src, *dst| dst.* = try arena.dupe(u8, src);
    out.benchmark.circuits = circuits;
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test "shipped settings file parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const s = try load(arena_state.allocator(), std.testing.io, default_path);
    try std.testing.expectEqualStrings("cfg/arch.toml", s.options.arch.?);
    try std.testing.expect(s.benchmark.circuits.len > 0);
    try std.testing.expect(s.benchmark.out_dir != null);
}

test "missing tables fall back to defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = toml.Parser(Settings).init(arena);
    defer parser.deinit();
    var raw = try parser.parseString("[options]\nverbose = true\n");
    defer raw.deinit();
    const s = try dupe(arena, raw.value);

    try std.testing.expect(s.options.arch == null);
    try std.testing.expect(s.options.verbose.?);
    try std.testing.expectEqual(@as(usize, 0), s.benchmark.circuits.len);
}

test "merge precedence: flag beats file beats built-in" {
    const file = Settings{ .options = .{ .arch = "file.toml", .viz = true } };
    const r = merge(file, .{ .arch = "flag.toml", .verbose = true });
    try std.testing.expectEqualStrings("flag.toml", r.arch);
    try std.testing.expect(r.viz); // file value survives: no flag given
    try std.testing.expect(r.verbose);

    const bare = merge(.{}, .{});
    try std.testing.expectEqualStrings("cfg/arch.toml", bare.arch);
    try std.testing.expect(!bare.viz);
    try std.testing.expect(!bare.verbose);
}
