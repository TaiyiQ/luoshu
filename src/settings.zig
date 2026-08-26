//! Run settings loaded from a TOML file, opt-in via `--cfg`. The file
//! encodes the input flags (--arch/--asm/--out) as an [options] table;
//! the CLI rejects mixing it with those flags, so `resolve` applies
//! exactly one source over the built-in defaults on `Resolved`.

const std = @import("std");
const toml = @import("toml");

/// Mirrors the [options] table: one key per input flag. Null means "not
/// set", leaving the built-in default. The CLI hands its parsed flags to
/// `resolve` in this shape too.
pub const Options = struct {
    arch: ?[]const u8 = null,
    assembly: ?[]const u8 = null,
    /// Directory the job outputs land in; each circuit writes
    /// <stem>-schedule.json and <stem>-bench.json. Null writes nothing.
    out: ?[]const u8 = null,
};

pub const Settings = struct {
    options: Options = .{},
};

/// Options with the one source applied. The field defaults are the
/// built-in layer: what a run uses when the source has no opinion.
pub const Resolved = struct {
    arch: []const u8 = "cfg/arch.toml",
    assembly: ?[]const u8 = null,
    out: ?[]const u8 = null,
};

/// Applies one source over the built-in defaults: the config file when
/// `path` is given (it must exist), the command-line flags otherwise.
/// The CLI rejects mixing, so at most one side carries values. Errors
/// only when loading a file.
pub fn resolve(arena: std.mem.Allocator, io: std.Io, flags: Options, path: ?[]const u8) !Resolved {
    const opts = if (path) |p| (try load(arena, io, p)).options else flags;
    var r = Resolved{};
    apply(&r, opts);
    return r;
}

fn apply(r: *Resolved, o: Options) void {
    if (o.arch) |v| r.arch = v;
    if (o.assembly) |v| r.assembly = v;
    if (o.out) |v| r.out = v;
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
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test "shipped settings file parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const s = try load(arena_state.allocator(), std.testing.io, "cfg/settings.toml");
    // Every key ships commented out: the built-in defaults suffice.
    try std.testing.expect(s.options.arch == null);
    try std.testing.expect(s.options.out == null);
}

test "config file values apply over defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = toml.Parser(Settings).init(arena);
    defer parser.deinit();
    var raw = try parser.parseString("[options]\nout = \"zig-out\"\n");
    defer raw.deinit();
    const s = try dupe(arena, raw.value);

    var r = Resolved{};
    apply(&r, s.options);
    try std.testing.expectEqualStrings("zig-out", r.out.?);
    try std.testing.expectEqualStrings("cfg/arch.toml", r.arch); // key absent
    try std.testing.expect(r.assembly == null);
}

test "flags apply over defaults" {
    var r = Resolved{};
    apply(&r, .{ .arch = "flag.toml" });
    try std.testing.expectEqualStrings("flag.toml", r.arch);
    try std.testing.expect(r.assembly == null);
    try std.testing.expect(r.out == null);
}

test "bare run uses built-in defaults" {
    var r = Resolved{};
    apply(&r, .{});
    try std.testing.expectEqualStrings("cfg/arch.toml", r.arch);
    try std.testing.expect(r.assembly == null);
    try std.testing.expect(r.out == null);
}
