//! End-to-end golden tests: each case parses a pinned .qasm and runs the
//! full pipeline (parse -> decompose -> route -> compile), asserting two
//! things:
//!
//! - correctness: verify.verify accepts the schedule, including CZ
//!   coverage against the decomposed pipeline, so neither an illegal
//!   schedule nor a silently dropped gate can pass;
//! - quality: the case's bench metrics match one line in
//!   testdata/metrics.json, so a routing regression shows up as a
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

/// Pinned copy of the architecture config: cfg/arch.toml is user-editable
/// for experiments, so the goldens compile against this frozen twin.
pub const arch_path = "testdata/arch.toml";

/// The metrics golden: one line of bench numbers per case, keyed by name.
pub const metrics_path = "testdata/metrics.json";

/// The golden corpus, ordered simplest-first per folder. Walked by the
/// metrics test below and by `zig build update-goldens`, so the
/// regenerator can never drift from the test.
pub const cases = [_][]const u8{
    "testdata/golden/01-even-cycle.qasm",
    "testdata/golden/02-pendant-cycle.qasm",
    "testdata/golden/03-grid.qasm",
    "testdata/golden/04-qft-5.qasm",
    "testdata/golden/bell/01-bell.qasm",
    "testdata/golden/bell/02-bell-serial.qasm",
    "testdata/golden/bell/03-bell-inter.qasm",
    "testdata/golden/reset/01-reuse.qasm",
    "testdata/golden/reset/02-register.qasm",
    "testdata/golden/reset/03-interleave.qasm",
    "testdata/golden/czpair/01-dup-adjacent.qasm",
    "testdata/golden/czpair/02-dup-reversed.qasm",
    "testdata/golden/czpair/03-dup-commuting-cz-between.qasm",
    "testdata/golden/czpair/04-dup-disjoint-u-between.qasm",
    "testdata/golden/czpair/05-dup-partner-u-between.qasm",
    "testdata/golden/czpair/06-dup-triple.qasm",
    "testdata/golden/czpair/07-dup-reset-between.qasm",
    "testdata/golden/czpair/08-dup-cx.qasm",
    "testdata/golden/czpair/09-dup-in-triangle.qasm",
};

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

/// Builds the metrics golden: one line of bench numbers per case, keyed by
/// name, in `cases` order. compile_ns is excluded (non-deterministic);
/// everything else is deterministic arithmetic over a deterministic
/// schedule, so the file is byte-stable.
pub fn metricsJson(gpa: std.mem.Allocator, io: std.Io, cfg: arch.ArchConfig) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");
    for (cases, 0..) |path, i| {
        errdefer std.debug.print("golden case failed: {s}\n", .{path});
        const m = try runCase(gpa, io, cfg, path);

        if (i > 0) try w.writeAll(",\n");
        try w.print(
            "  \"{s}\": {{ \"qubits\": {d}, \"frames\": {d}, \"load\": {d}, \"store\": {d}, " ++
                "\"move\": {d}, \"rydberg\": {d}, \"raman\": {d}, \"measure\": {d}, \"reset\": {d}, " ++
                "\"cz_pairs\": {d}, \"cz_requested\": {d}, \"colors\": {d}, \"max_degree\": {d}, " ++
                "\"total_move_nm\": {d:.1}, \"max_move_nm\": {d:.1}, \"total_us\": {d:.3} }}",
            .{
                caseName(path), m.num_qubits,     m.frames,   m.n_load,       m.n_store,
                m.n_move,       m.n_rydberg,      m.n_raman,  m.n_measure,    m.n_reset,
                m.cz_pairs,     m.cz_requested.?, m.colors.?, m.max_degree.?, m.total_move_nm,
                m.max_move_nm,  m.totalUs(),
            },
        );
    }
    try w.writeAll("\n}");

    return gpa.dupe(u8, buf.written());
}

test "golden: metrics match testdata/metrics.json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    const json = try metricsJson(gpa, io, cfg);
    defer gpa.free(json);

    try serialize.expectMatchesFile(gpa, io, metrics_path, json);
}

// The two mistake fixtures are not golden cases: they pin the parser's
// rejections through the same load path the goldens use.
test "mistake: cz on a single qubit is rejected" {
    try std.testing.expectError(error.ParseError, qasm.load(
        std.testing.allocator,
        std.testing.io,
        "testdata/golden/czpair/10-mistake-self-cz.qasm",
    ));
}

test "mistake: cz on an undeclared register is rejected" {
    try std.testing.expectError(error.UnknownRegister, qasm.load(
        std.testing.allocator,
        std.testing.io,
        "testdata/golden/czpair/11-mistake-undeclared.qasm",
    ));
}

test {
    std.testing.refAllDecls(@This());
}
