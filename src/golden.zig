//! End-to-end golden tests: each case runs the full pipeline (circuit ->
//! decompose -> route -> compile) and byte-compares the logical routing
//! output (Sequence JSON, one object per CZ stage) and the physical
//! schedule (Hardware JSON) against checked-in snapshots in testdata/.
//!
//! Snapshots pin stability, not correctness: any change to MIS/coloring/
//! choreography shows up as a reviewable diff. Regenerate with `zig build
//! update-snapshots`. Correctness comes from verify.verify, which runs in
//! every case, so a blessed snapshot is always a legal schedule.

const std = @import("std");
const arch = @import("arch");
const assembly = @import("assembly");
const circuit = @import("circuit");
const qasm = @import("qasm");
const compiler = @import("compiler");
const serialize = @import("serialize");
const verify = @import("verify");

pub const arch_path = "cfg/arch.toml";

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
};

pub fn buildCircuit(kind: Kind, gpa: std.mem.Allocator) !circuit.Circuit {
    return switch (kind) {
        .bell => buildBell(gpa),
        .ghz3 => buildGhz3(gpa),
        .grid => buildGrid(gpa),
        .qft5 => buildQft5(gpa),
        .cycle6 => buildCycle6(gpa),
        .cyclic_aod => buildCyclicAod(gpa),
    };
}

pub const Case = struct {
    kind: Kind,
    sequence_path: []const u8,
    hardware_path: []const u8,
};

/// Walked by the per-case tests below and by `zig build update-snapshots`,
/// so the regenerator can never drift from the tests.
pub const cases = [_]Case{
    .{
        .kind = .bell,
        .sequence_path = "testdata/bell.sequence.json",
        .hardware_path = "testdata/bell.hardware.json",
    },
    .{
        .kind = .ghz3,
        .sequence_path = "testdata/ghz-3.sequence.json",
        .hardware_path = "testdata/ghz-3.hardware.json",
    },
    .{
        .kind = .grid,
        .sequence_path = "testdata/grid.sequence.json",
        .hardware_path = "testdata/grid.hardware.json",
    },
    .{
        .kind = .qft5,
        .sequence_path = "testdata/qft-5.sequence.json",
        .hardware_path = "testdata/qft-5.hardware.json",
    },
    .{
        .kind = .cycle6,
        .sequence_path = "testdata/cycle-6.sequence.json",
        .hardware_path = "testdata/cycle-6.hardware.json",
    },
    .{
        .kind = .cyclic_aod,
        .sequence_path = "testdata/cyclic-aod.sequence.json",
        .hardware_path = "testdata/cyclic-aod.hardware.json",
    },
};

pub fn buildBell(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 2);
    errdefer c.deinit();
    try c.h(0);
    try c.cx(0, 1);
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

// CZ ring over 6 qubits — mirrors route.buildCycleGraph. Its first
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

/// Serializes the routing output of every CZ-carrying stage as a JSON array,
/// one Sequence object per routing round (a stage routes in rounds until
/// every CZ is covered). U-only stages route nothing and are skipped.
pub fn sequencesJson(gpa: std.mem.Allocator, pipe: *circuit.Pipeline) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("[\n");
    var first = true;
    for (pipe.stages.items) |*stage| {
        if (stage.cz_gates.items.len == 0) continue;

        const seqs = try compiler.routeStage(gpa, stage.cz_gates.items, pipe.num_qubits, null);
        defer {
            for (seqs) |*s| s.deinit();
            gpa.free(seqs);
        }

        for (seqs) |*seq| {
            const json = try serialize.sequenceToJson(gpa, seq.fixed, seq.moveable);
            defer gpa.free(json);

            if (!first) try w.writeAll(",\n");
            first = false;
            try w.writeAll(json);
        }
    }
    try w.writeAll("\n]");

    return gpa.dupe(u8, buf.written());
}

/// Runs `case` through the full pipeline and returns both snapshot payloads,
/// verifying the schedule on the way so an illegal one can never be blessed
/// as a golden baseline. Shared by the per-case tests and
/// `zig build update-snapshots`, so the two can never drift.
pub fn caseJson(
    gpa: std.mem.Allocator,
    cfg: arch.ArchConfig,
    case: Case,
) !struct { seq: []u8, hw: []u8 } {
    var circ = try buildCircuit(case.kind, gpa);
    defer circ.deinit();

    var pipe = try circuit.decompose(gpa, circ);
    defer pipe.deinit();

    const seq_json = try sequencesJson(gpa, &pipe);
    errdefer gpa.free(seq_json);

    var hw = try compiler.compile(gpa, &pipe, cfg, null, null);
    defer hw.deinit();

    try verify.verify(gpa, &hw);

    const hw_json = try serialize.hardwareToJson(gpa, &hw);
    return .{ .seq = seq_json, .hw = hw_json };
}

fn goldenCase(case: Case) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    const json = try caseJson(gpa, cfg, case);
    defer gpa.free(json.seq);
    defer gpa.free(json.hw);

    try serialize.expectMatchesFile(gpa, io, case.sequence_path, json.seq);
    try serialize.expectMatchesFile(gpa, io, case.hardware_path, json.hw);
}

test "golden: bell" {
    try goldenCase(cases[0]);
}

test "golden: ghz-3" {
    try goldenCase(cases[1]);
}

test "golden: grid" {
    try goldenCase(cases[2]);
}

test "golden: qft-5" {
    try goldenCase(cases[3]);
}

test "golden: cycle-6" {
    try goldenCase(cases[4]);
}

test "golden: cyclic-aod" {
    try goldenCase(cases[5]);
}

// Not a snapshot test: pins down that an explicit assembly handoff (a fully
// occupied storage grid, of which qft-5 uses only its first 5 atoms) still
// compiles to a schedule the verifier accepts.
test "assembly: qft-5 compiles legally from assembly.json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const asm_doc = try assembly.load(gpa, io, "cfg/assembly.json");
    defer asm_doc.deinit(gpa);

    var circ = try buildQft5(gpa);
    defer circ.deinit();

    var pipe = try circuit.decompose(gpa, circ);
    defer pipe.deinit();

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    var hw = try compiler.compile(gpa, &pipe, cfg, asm_doc.sites, null);
    defer hw.deinit();

    try verify.verify(gpa, &hw);
}

/// The CLI input path: parse a vendored .qasm with qasm.load (the case
/// builders construct Circuits directly, bypassing the parser) and require
/// a schedule the verifier accepts. Not a snapshot test, so it pins the
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

    try verify.verify(gpa, &hw);
}

test "qasm: bell compiles legally from testdata/bell.qasm" {
    try qasmCompilesLegally("testdata/bell.qasm");
}

// All six CZs land in one stage and route as a single pickup round.
test "qasm: cyclic-aod compiles legally from testdata/cyclic-aod.qasm" {
    try qasmCompilesLegally("testdata/cyclic-aod.qasm");
}

test {
    std.testing.refAllDecls(@This());
}
