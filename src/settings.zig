//! Run settings loaded from a TOML file (default: config/settings.toml).
//! The file encodes the CLI arguments so a bare `gatecomp` invocation is
//! reproducible; explicit command-line flags override these values — the
//! merge lives in cli.parseArgs.

const std = @import("std");
const toml = @import("toml");

pub const default_path = "config/settings.toml";

/// Mirrors the [options] table: one key per CLI flag. Null means "not set",
/// so cli.zig can tell a settings value from a built-in default.
pub const Options = struct {
    arch: ?[]const u8 = null,
    assembly: ?[]const u8 = null,
    out: ?[]const u8 = null,
    bench: ?[]const u8 = null,
    draw: ?bool = null,
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
    try std.testing.expectEqualStrings("config/arch.toml", s.options.arch.?);
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
