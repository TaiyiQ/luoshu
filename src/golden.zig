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

pub const Case = struct {
    /// Circuit in the testdata/golden/ corpus, grouped by suite folder.
    path: []const u8,

    /// Key in testdata/metrics.json: the path relative to testdata/golden/
    /// without the extension.
    name: []const u8,
};

/// The metrics golden: one line of bench numbers per case, keyed by name.
pub const metrics_path = "testdata/metrics.json";

/// Walked by the per-case tests below and by `zig build update-goldens`,
/// so the regenerator can never drift from the tests.
pub const cases = [_]Case{
    .{ .path = "testdata/golden/01-even-cycle.qasm", .name = "01-even-cycle" },
    .{ .path = "testdata/golden/02-pendant-cycle.qasm", .name = "02-pendant-cycle" },
    .{ .path = "testdata/golden/03-grid.qasm", .name = "03-grid" },
    .{ .path = "testdata/golden/04-qft-5.qasm", .name = "04-qft-5" },
    .{ .path = "testdata/golden/bell/01-bell.qasm", .name = "bell/01-bell" },
    .{ .path = "testdata/golden/bell/02-bell-serial.qasm", .name = "bell/02-bell-serial" },
    .{ .path = "testdata/golden/bell/03-bell-inter.qasm", .name = "bell/03-bell-inter" },
    .{ .path = "testdata/golden/reset/01-reuse.qasm", .name = "reset/01-reuse" },
    .{ .path = "testdata/golden/reset/02-register.qasm", .name = "reset/02-register" },
    .{ .path = "testdata/golden/reset/03-interleave.qasm", .name = "reset/03-interleave" },
    .{ .path = "testdata/golden/czpair/01-dup-adjacent.qasm", .name = "czpair/01-dup-adjacent" },
    .{ .path = "testdata/golden/czpair/02-dup-reversed.qasm", .name = "czpair/02-dup-reversed" },
    .{ .path = "testdata/golden/czpair/03-dup-commuting-cz-between.qasm", .name = "czpair/03-dup-commuting-cz-between" },
    .{ .path = "testdata/golden/czpair/04-dup-disjoint-u-between.qasm", .name = "czpair/04-dup-disjoint-u-between" },
    .{ .path = "testdata/golden/czpair/05-dup-partner-u-between.qasm", .name = "czpair/05-dup-partner-u-between" },
    .{ .path = "testdata/golden/czpair/06-dup-triple.qasm", .name = "czpair/06-dup-triple" },
    .{ .path = "testdata/golden/czpair/07-dup-reset-between.qasm", .name = "czpair/07-dup-reset-between" },
    .{ .path = "testdata/golden/czpair/08-dup-cx.qasm", .name = "czpair/08-dup-cx" },
    .{ .path = "testdata/golden/czpair/09-dup-in-triangle.qasm", .name = "czpair/09-dup-in-triangle" },
};

/// Parses the case's .qasm, runs it through the full pipeline, verifies
/// the schedule (CZ coverage included), and returns the bench metrics.
/// Shared by the tests and `zig build update-goldens`, so an illegal or
/// lossy schedule can never be blessed as a baseline.
pub fn runCase(gpa: std.mem.Allocator, io: std.Io, cfg: arch.ArchConfig, path: []const u8) !bench.Metrics {
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
    for (cases, 0..) |case, i| {
        const m = try runCase(gpa, io, cfg, case.path);

        if (i > 0) try w.writeAll(",\n");
        try w.print(
            "  \"{s}\": {{ \"qubits\": {d}, \"frames\": {d}, \"load\": {d}, \"store\": {d}, " ++
                "\"move\": {d}, \"rydberg\": {d}, \"raman\": {d}, \"measure\": {d}, \"reset\": {d}, " ++
                "\"cz_pairs\": {d}, \"cz_requested\": {d}, \"colors\": {d}, \"max_degree\": {d}, " ++
                "\"total_move_nm\": {d:.1}, \"max_move_nm\": {d:.1}, \"total_us\": {d:.3} }}",
            .{
                case.name,     m.num_qubits,     m.frames,   m.n_load,       m.n_store,
                m.n_move,      m.n_rydberg,      m.n_raman,  m.n_measure,    m.n_reset,
                m.cz_pairs,    m.cz_requested.?, m.colors.?, m.max_degree.?, m.total_move_nm,
                m.max_move_nm, m.totalUs(),
            },
        );
    }
    try w.writeAll("\n}");

    return gpa.dupe(u8, buf.written());
}

/// Runs the case with the given metrics key, so each test names its case
/// instead of indexing into `cases` (an index slip would silently run the
/// wrong circuit).
fn goldenCase(name: []const u8) !bench.Metrics {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const case = for (cases) |c| {
        if (std.mem.eql(u8, c.name, name)) break c;
    } else return error.NoSuchCase;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    return runCase(gpa, io, cfg, case.path);
}

test "golden: 01-even-cycle" {
    _ = try goldenCase("01-even-cycle");
}

test "golden: 02-pendant-cycle" {
    _ = try goldenCase("02-pendant-cycle");
}

test "golden: 03-grid" {
    _ = try goldenCase("03-grid");
}

test "golden: 04-qft-5" {
    _ = try goldenCase("04-qft-5");
}

test "golden: bell/01-bell" {
    _ = try goldenCase("bell/01-bell");
}

test "golden: bell/02-bell-serial" {
    _ = try goldenCase("bell/02-bell-serial");
}

test "golden: bell/03-bell-inter" {
    _ = try goldenCase("bell/03-bell-inter");
}

test "golden: reset/01-reuse" {
    const m = try goldenCase("reset/01-reuse");
    try std.testing.expect(m.n_reset >= 1);
}

test "golden: reset/02-register" {
    const m = try goldenCase("reset/02-register");
    try std.testing.expect(m.n_reset >= 1);
}

test "golden: reset/03-interleave" {
    const m = try goldenCase("reset/03-interleave");
    try std.testing.expect(m.n_reset >= 1);
}

test "golden: czpair/01-dup-adjacent" {
    _ = try goldenCase("czpair/01-dup-adjacent");
}

test "golden: czpair/02-dup-reversed" {
    _ = try goldenCase("czpair/02-dup-reversed");
}

test "golden: czpair/03-dup-commuting-cz-between" {
    _ = try goldenCase("czpair/03-dup-commuting-cz-between");
}

test "golden: czpair/04-dup-disjoint-u-between" {
    _ = try goldenCase("czpair/04-dup-disjoint-u-between");
}

test "golden: czpair/05-dup-partner-u-between" {
    _ = try goldenCase("czpair/05-dup-partner-u-between");
}

test "golden: czpair/06-dup-triple" {
    _ = try goldenCase("czpair/06-dup-triple");
}

test "golden: czpair/07-dup-reset-between" {
    _ = try goldenCase("czpair/07-dup-reset-between");
}

test "golden: czpair/08-dup-cx" {
    _ = try goldenCase("czpair/08-dup-cx");
}

test "golden: czpair/09-dup-in-triangle" {
    _ = try goldenCase("czpair/09-dup-in-triangle");
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

test "golden: metrics match testdata/metrics.json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    const json = try metricsJson(gpa, io, cfg);
    defer gpa.free(json);

    try serialize.expectMatchesFile(gpa, io, metrics_path, json);
}

// Not a golden case: pins down that an explicit assembly handoff (a fully
// occupied storage grid, of which qft-5 uses only its first 5 atoms) still
// compiles to a schedule the verifier accepts.
test "assembly: qft-5 compiles legally from assembly.json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const asm_doc = try assembly.load(gpa, io, "testdata/assembly.json");
    defer asm_doc.deinit(gpa);

    var circ = try qasm.load(gpa, io, "testdata/golden/04-qft-5.qasm");
    defer circ.deinit();

    var pipe = try circuit.decompose(gpa, circ);
    defer pipe.deinit();

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    var hw = try compiler.compile(gpa, &pipe, cfg, asm_doc.sites, null);
    defer hw.deinit();

    const wanted = try pipe.czPairs(gpa);
    defer gpa.free(wanted);

    try verify.verify(gpa, &hw, wanted);
}

test {
    std.testing.refAllDecls(@This());
}
