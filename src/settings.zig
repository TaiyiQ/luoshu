//! Run settings loaded from a TOML file (default: cfg/settings.toml).
//! The file encodes the CLI flags so a plain `gatecomp <circuit>` run
//! needs none. `resolve` layers the three sources: command-line flags
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
    /// Directory the job outputs land in; each circuit writes
    /// <stem>-schedule.json and <stem>-bench.json. Null writes nothing.
    out: ?[]const u8 = null,
    viz: ?bool = null,
    verbose: ?bool = null,
};

pub const Settings = struct {
    options: Options = .{},
};

/// Options with every layer applied. The field defaults are the built-in
/// layer: what a bare run uses when neither the settings file nor the
/// command line has an opinion.
pub const Resolved = struct {
    arch: []const u8 = "cfg/arch.toml",
    assembly: ?[]const u8 = null,
    out: ?[]const u8 = null,
    viz: bool = false,
    verbose: bool = false,
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
    var r = Resolved{};
    apply(&r, cfg.options);
    apply(&r, flags);
    return r;
}

fn apply(r: *Resolved, o: Options) void {
    if (o.arch) |v| r.arch = v;
    if (o.assembly) |v| r.assembly = v;
    if (o.out) |v| r.out = v;
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
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test "shipped settings file parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const s = try load(arena_state.allocator(), std.testing.io, default_path);
    // Every key ships commented out: the built-in defaults suffice.
    try std.testing.expect(s.options.arch == null);
    try std.testing.expect(s.options.out == null);
}

test "missing keys fall back to defaults" {
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
