//! End-to-end golden tests: each case runs the full pipeline
//! (circuit -> decompose -> route -> compile) and asserts two things:
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

/// One tag per golden circuit. Cases name their circuit by tag and
/// buildCircuit dispatches exhaustively, so an unused builder or a case
/// without a builder fails to compile.
pub const Kind = enum {
    bell,
    ghz3,
    grid,
    qft5,
    cycle6,
    cyclic_aod,
    bell_reset,
};

pub fn buildCircuit(kind: Kind, gpa: std.mem.Allocator) !circuit.Circuit {
    return switch (kind) {
        .bell => buildBell(gpa),
        .ghz3 => buildGhz3(gpa),
        .grid => buildGrid(gpa),
        .qft5 => buildQft5(gpa),
        .cycle6 => buildCycle6(gpa),
        .cyclic_aod => buildCyclicAod(gpa),
        .bell_reset => buildBellReset(gpa),
    };
}

pub const Case = struct {
    kind: Kind,

    /// Key in testdata/metrics.json.
    name: []const u8,
};

/// The metrics golden: one line of bench numbers per case, keyed by name.
pub const metrics_path = "testdata/metrics.json";

/// Walked by the per-case tests below and by `zig build update-goldens`,
/// so the regenerator can never drift from the tests.
pub const cases = [_]Case{
    .{ .kind = .bell, .name = "bell" },
    .{ .kind = .ghz3, .name = "ghz-3" },
    .{ .kind = .grid, .name = "grid" },
    .{ .kind = .qft5, .name = "qft-5" },
    .{ .kind = .cycle6, .name = "cycle-6" },
    .{ .kind = .cyclic_aod, .name = "cyclic-aod" },
    .{ .kind = .bell_reset, .name = "bell-reset" },
};

pub fn buildBell(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 2);
    errdefer c.deinit();
    try c.h(0);
    try c.cx(0, 1);
    return c;
}

// Bell pair with a mid-circuit reset on q0. The case exercises the whole
// round trip — shuttle out, readout-zone repump, shuttle home — and the
// frame-phase zeroing: reset(0) voids q0's virtual-Z reference (pi after
// the first H), so the trailing H fires with a different drive phase than
// it would without the zeroing.
pub fn buildBellReset(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 2);
    errdefer c.deinit();
    try c.h(0);
    try c.cx(0, 1);
    try c.reset(0);
    try c.h(0);
    return c;
}

pub fn buildGhz3(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 3);
    errdefer c.deinit();
    try c.h(0);
    try c.cx(0, 1);
    try c.cx(1, 2);
    return c;
}

// CZ on every edge of a 3x3 grid — one big stage, maximum routing pressure.
//
// 0-1-2
// | | |
// 3-4-5
// | | |
// 6-7-8
pub fn buildGrid(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 9);
    errdefer c.deinit();
    try c.cz(0, 1);
    try c.cz(1, 2);
    try c.cz(3, 4);
    try c.cz(4, 5);
    try c.cz(6, 7);
    try c.cz(7, 8);
    try c.cz(0, 3);
    try c.cz(3, 6);
    try c.cz(1, 4);
    try c.cz(4, 7);
    try c.cz(2, 5);
    try c.cz(5, 8);
    return c;
}

// CZ ring over 6 qubits — the even cycle from route.zig's coverage
// test, taken through the full pipeline. Its first
// timeframe places the AOD atoms away from the leftmost compute columns,
// pinning down that the entry move stores atoms directly at their
// first-timeframe positions.
pub fn buildCycle6(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 6);
    errdefer c.deinit();
    try c.cz(0, 1);
    try c.cz(1, 2);
    try c.cz(2, 3);
    try c.cz(3, 4);
    try c.cz(4, 5);
    try c.cz(5, 0);
    return c;
}

// Five-cycle 0-1-3-4-2-0 with a pendant qubit 5 on 1 (mirrors
// qasm/cyclic-aod.qasm). Historically forced CyclicAodOrder and a
// split-into-rounds fallback in the driver; coloring against the fixed AOD
// sequence (arXiv:2405.08068) rejects conflicting colors during coloring,
// so it routes in a single pickup. Kept as the regression case for that
// coloring. A single round still leaves one SLM-SLM edge uncovered (the odd
// cycle is non-bipartite); the driver reroutes the residue in a further
// round, so every CZ lands in the schedule.
pub fn buildCyclicAod(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 6);
    errdefer c.deinit();
    try c.cz(0, 1);
    try c.cz(0, 2);
    try c.cz(1, 3);
    try c.cz(1, 5);
    try c.cz(2, 4);
    try c.cz(3, 4);
    return c;
}

// QFT-shaped interaction pattern on 5 qubits: H per qubit, then a CZ between
// every pair (the controlled-phase skeleton) — complete-graph routing.
pub fn buildQft5(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 5);
    errdefer c.deinit();
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try c.h(i);
        var j = i + 1;
        while (j < 5) : (j += 1) try c.cz(i, j);
    }
    return c;
}

/// Runs `kind` through the full pipeline, verifies the schedule (CZ
/// coverage included), and returns the bench metrics. Shared by the tests
/// and `zig build update-goldens`, so an illegal or lossy schedule can
/// never be blessed as a baseline.
pub fn runCase(gpa: std.mem.Allocator, cfg: arch.ArchConfig, kind: Kind) !bench.Metrics {
    var circ = try buildCircuit(kind, gpa);
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
pub fn metricsJson(gpa: std.mem.Allocator, cfg: arch.ArchConfig) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");
    for (cases, 0..) |case, i| {
        const m = try runCase(gpa, cfg, case.kind);

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

fn goldenCase(case: Case) !bench.Metrics {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    return runCase(gpa, cfg, case.kind);
}

test "golden: bell" {
    _ = try goldenCase(cases[0]);
}

test "golden: ghz-3" {
    _ = try goldenCase(cases[1]);
}

test "golden: grid" {
    _ = try goldenCase(cases[2]);
}

test "golden: qft-5" {
    _ = try goldenCase(cases[3]);
}

test "golden: cycle-6" {
    _ = try goldenCase(cases[4]);
}

test "golden: cyclic-aod" {
    _ = try goldenCase(cases[5]);
}

test "golden: bell-reset" {
    const m = try goldenCase(cases[6]);
    try std.testing.expect(m.n_reset >= 1);
    try std.testing.expect(m.n_measure >= 1);
}

test "golden: metrics match testdata/metrics.json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    const json = try metricsJson(gpa, cfg);
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

    var circ = try buildQft5(gpa);
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

/// The CLI input path: parse a vendored .qasm with qasm.load (the case
/// builders construct Circuits directly, bypassing the parser) and require
/// a schedule the verifier accepts. Not a golden case, so it pins the
/// parser-to-schedule path without freezing its output.
fn qasmCompilesLegally(path: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var circ = try qasm.load(gpa, io, path);
    defer circ.deinit();

    var pipe = try circuit.decompose(gpa, circ);
    defer pipe.deinit();

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    var hw = try compiler.compile(gpa, &pipe, cfg, null, null);
    defer hw.deinit();

    const wanted = try pipe.czPairs(gpa);
    defer gpa.free(wanted);

    try verify.verify(gpa, &hw, wanted);
}

test "qasm: bell compiles legally from testdata/bell.qasm" {
    try qasmCompilesLegally("testdata/bell.qasm");
}

// All six CZs land in one stage and route as a single pickup round.
test "qasm: cyclic-aod compiles legally from testdata/cyclic-aod.qasm" {
    try qasmCompilesLegally("testdata/cyclic-aod.qasm");
}

test "qasm: reset compiles legally from testdata/reset.qasm" {
    try qasmCompilesLegally("testdata/reset.qasm");
}

// A repeated pair "separated" only by a gate on an unrelated qubit: the
// disjoint h never advances the pair's cursors, so only decompose's
// pair-split keeps the repeat out of the first stage. Coverage then
// proves both pulses fired.
test "qasm: cz-repeat-disjoint compiles legally from testdata/cz-repeat-disjoint.qasm" {
    try qasmCompilesLegally("testdata/cz-repeat-disjoint.qasm");
}

// A repeated edge on a triangle: the pair-split composes with routing's
// multi-round residue loop (the triangle alone forces a residue round).
test "qasm: cz-repeat-triangle compiles legally from testdata/cz-repeat-triangle.qasm" {
    try qasmCompilesLegally("testdata/cz-repeat-triangle.qasm");
}

test {
    std.testing.refAllDecls(@This());
}
