//! End-to-end golden tests: each case parses a pinned .qasm and runs the
//! full pipeline (parse -> decompose -> route -> compile), asserting two
//! things:
//!
//! - correctness: verify.verify accepts the schedule, including CZ
//!   coverage against the decomposed pipeline, so neither an illegal
//!   schedule nor a silently dropped gate can pass;
//! - quality: the case's bench metrics match one row in
//!   testdata/metrics.txt, so a routing regression shows up as a
//!   one-line reviewable diff instead of hundreds of coordinates.
//!   Regenerate with `zig build update-goldens`.

const std = @import("std");
const arch = @import("arch");
const assembly = @import("assembly");
const bench = @import("bench");
const circuit = @import("circuit");
const qasm = @import("qasm");
const compiler = @import("compiler");
const serialize = @import("serialize");
const verify = @import("verify");

pub const arch_path = "testdata/arch.toml";
pub const metrics_path = "testdata/metrics.txt";
pub const golden_dir = "testdata/golden";

fn collectCases(gpa: std.mem.Allocator, io: std.Io) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }

    var dir = try std.Io.Dir.cwd().openDir(
        io,
        golden_dir,
        .{ .iterate = true },
    );
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".qasm")) continue;
        const full = try std.fmt.allocPrint(gpa, golden_dir ++ "/{s}", .{entry.path});
        errdefer gpa.free(full);
        try list.append(gpa, full);
    }

    // An empty corpus means the walk ran against the wrong directory.
    if (list.items.len == 0) return error.EmptyGoldenCorpus;

    // Paths are sorted to keep metrics.txt byte-stable; within each folder
    // the number prefixes make sorted order the simplest-first order.
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return list.toOwnedSlice(gpa);
}

/// Metrics key for a corpus path: the path under testdata/golden/, minus
/// the extension.
fn caseName(path: []const u8) []const u8 {
    const prefix = "testdata/golden/";
    std.debug.assert(std.mem.startsWith(u8, path, prefix));
    std.debug.assert(std.mem.endsWith(u8, path, ".qasm"));
    return path[prefix.len .. path.len - ".qasm".len];
}

/// Parses the case's .qasm, runs it through the full pipeline, verifies
/// the schedule (CZ coverage included), and returns the bench metrics.
/// Shared by the tests and `zig build update-goldens`, so an illegal or
/// lossy schedule can never be blessed as a baseline.
pub fn runCase(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: arch.ArchConfig,
    path: []const u8,
) !bench.Metrics {
    var circ = try qasm.load(gpa, io, path);
    defer circ.deinit();

    var pipe = try circuit.decompose(gpa, circ);
    defer pipe.deinit();

    var stats = compiler.RouteStats{};
    var hw = try compiler.compile(gpa, &pipe, cfg, null, &stats);
    defer hw.deinit();

    const wanted = try pipe.czPairs(gpa);
    defer gpa.free(wanted);

    try verify.verify(gpa, &hw, wanted);

    var m = bench.measure(&hw);
    m.cz_requested = stats.cz_requested;
    m.colors = stats.colors;
    m.max_degree = stats.max_degree;

    return m;
}

// One aligned column per bench field, so the table scans down as well as
// across. Header and rows share the widths; case names are left-aligned,
// numbers right-aligned.
const table_header =
    "{s:<36}" ++ // case
    "{s:>7}" ++ // qubits
    "{s:>8}" ++ // frames
    "{s:>6}" ++ // load
    "{s:>7}" ++ // store
    "{s:>6}" ++ // move
    "{s:>9}" ++ // rydberg
    "{s:>7}" ++ // raman
    "{s:>9}" ++ // measure
    "{s:>7}" ++ // reset
    "{s:>4}" ++ // cz
    "{s:>8}" ++ // cz_req
    "{s:>8}" ++ // colors
    "{s:>5}" ++ // deg
    "{s:>13}" ++ // move_nm
    "{s:>11}" ++ // max_nm
    "{s:>11}" ++ // us
    "\n";

const table_row =
    "{s:<36}" ++ // case
    "{d:>7}" ++ // qubits
    "{d:>8}" ++ // frames
    "{d:>6}" ++ // load
    "{d:>7}" ++ // store
    "{d:>6}" ++ // move
    "{d:>9}" ++ // rydberg
    "{d:>7}" ++ // raman
    "{d:>9}" ++ // measure
    "{d:>7}" ++ // reset
    "{d:>4}" ++ // cz
    "{d:>8}" ++ // cz_req
    "{d:>8}" ++ // colors
    "{d:>5}" ++ // deg
    "{d:>13.1}" ++ // move_nm
    "{d:>11.1}" ++ // max_nm
    "{d:>11.3}" ++ // us
    "\n";

/// Builds the metrics golden: one table row of bench numbers per case,
/// in sorted path order. compile_ns is excluded (non-deterministic);
/// everything else is deterministic arithmetic over a deterministic
/// schedule, so the file is byte-stable.
pub fn metricsTable(gpa: std.mem.Allocator, io: std.Io, cfg: arch.ArchConfig) ![]u8 {
    const paths = try collectCases(gpa, io);
    defer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    const w = &buf.writer;

    try w.print(table_header, .{
        "case",    "qubits",  "frames", "load", "store",  "move",   "rydberg",
        "raman",   "measure", "reset",  "cz",   "cz_req", "colors", "deg",
        "move_nm", "max_nm",  "us",
    });

    for (paths) |path| {
        errdefer std.debug.print("golden case failed: {s}\n", .{path});
        const m = try runCase(gpa, io, cfg, path);

        try w.print(table_row, .{
            caseName(path), m.num_qubits,     m.frames,   m.n_load,       m.n_store,
            m.n_move,       m.n_rydberg,      m.n_raman,  m.n_measure,    m.n_reset,
            m.cz_pairs,     m.cz_requested.?, m.colors.?, m.max_degree.?, m.total_move_nm,
            m.max_move_nm,  m.totalUs(),
        });
    }

    return gpa.dupe(u8, buf.written());
}

// Entry point of `zig build update-goldens`.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    const table = try metricsTable(gpa, io, cfg);
    defer gpa.free(table);

    try serialize.writeJsonFile(io, metrics_path, table);

    std.debug.print("wrote {s}\n", .{metrics_path});
}

test "golden: metrics match testdata/metrics.txt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    const table = try metricsTable(gpa, io, cfg);
    defer gpa.free(table);

    try serialize.expectMatchesFile(gpa, io, metrics_path, table);
}

test {
    std.testing.refAllDecls(@This());
}
