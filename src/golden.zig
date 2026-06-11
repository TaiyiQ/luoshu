//! Golden tests over the compiler's IR boundaries. For each named circuit
//! the logical routing output (Sequence JSON, one object per CZ stage) and
//! the physical schedule (Hardware JSON) are compared byte-for-byte against
//! checked-in snapshots in testdata/.
//!
//! Any change to MIS/coloring/choreography shows up as a reviewable diff.
//! Regenerate with `zig build update-snapshots`.
const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");
const serialize = @import("serialize");

pub const arch_path = "example/arch.toml";

pub const CircuitBuilder = *const fn (std.mem.Allocator) anyerror!circuit.Circuit;

pub const Case = struct {
    name: []const u8,
    build: CircuitBuilder,
    sequence_path: []const u8,
    hardware_path: []const u8,
};

pub const cases = [_]Case{
    .{
        .name = "bell",
        .build = buildBell,
        .sequence_path = "testdata/bell.sequence.json",
        .hardware_path = "testdata/bell.hardware.json",
    },
    .{
        .name = "ghz-3",
        .build = buildGhz3,
        .sequence_path = "testdata/ghz-3.sequence.json",
        .hardware_path = "testdata/ghz-3.hardware.json",
    },
    .{
        .name = "grid",
        .build = buildGrid,
        .sequence_path = "testdata/grid.sequence.json",
        .hardware_path = "testdata/grid.hardware.json",
    },
    .{
        .name = "qft-5",
        .build = buildQft5,
        .sequence_path = "testdata/qft-5.sequence.json",
        .hardware_path = "testdata/qft-5.hardware.json",
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

// QFT-shaped interaction pattern on 5 qubits: H per qubit, then a CZ between
// every pair (the controlled-phase skeleton) — complete-graph routing.
pub fn buildQft5(gpa: std.mem.Allocator) !circuit.Circuit {
    var c = circuit.Circuit.init(gpa, 5);
    errdefer c.deinit();
    for (0..5) |i| {
        try c.h(i);
        for (i + 1..5) |j| try c.cz(i, j);
    }
    return c;
}

/// Serializes the routing output of every CZ-carrying stage as a JSON array,
/// one Sequence object per stage. U-only stages route nothing and are skipped.
pub fn sequencesJson(gpa: std.mem.Allocator, pipe: *circuit.Pipeline) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("[\n");
    var first = true;
    for (pipe.stages.items) |*stage| {
        if (stage.cz_gates.items.len == 0) continue;

        var seq = try stage.computeSequence(gpa, pipe.num_qubits);
        defer seq.deinit();

        const json = try serialize.sequenceToJson(gpa, seq.fixed, seq.moveable);
        defer gpa.free(json);

        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll(json);
    }
    try w.writeAll("\n]");

    return gpa.dupe(u8, buf.written());
}

fn expectMatchesFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    actual: []const u8,
) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                "\nSnapshot missing: {s}\n" ++
                    "  Run `zig build update-snapshots` to generate it.\n",
                .{path},
            );
        }
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const expected = try gpa.alloc(u8, stat.size);
    defer gpa.free(expected);
    _ = try file.readPositionalAll(io, expected, 0);

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print(
            "\nSnapshot mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
            .{ path, expected, actual },
        );
        return error.SnapshotMismatch;
    }
}

fn goldenCase(case: Case) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var circ = try case.build(gpa);
    defer circ.deinit();

    var pipe = try circuit.decompose(gpa, circ);
    defer pipe.deinit();

    const seq_json = try sequencesJson(gpa, &pipe);
    defer gpa.free(seq_json);
    try expectMatchesFile(gpa, io, case.sequence_path, seq_json);

    const cfg = try arch.load(gpa, io, arch_path);
    defer cfg.deinit(gpa);

    var hw = try pipe.compile(cfg);
    defer hw.deinit();

    const hw_json = try serialize.hardwareToJson(gpa, &hw);
    defer gpa.free(hw_json);
    try expectMatchesFile(gpa, io, case.hardware_path, hw_json);
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

test {
    @import("testutil").refAllDeclsRecursive(@This());
}
