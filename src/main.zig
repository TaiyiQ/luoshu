const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const assembly = @import("assembly");
const circuit = @import("circuit");
const qasm = @import("qasm");
const compiler = @import("compiler");
const bench = @import("bench");
const draw = @import("draw");
const serialize = @import("serialize");
const trace = @import("trace");
const verify = @import("verify");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const opts = try cli.parseArgs(arena, init.io, init.minimal.args);
    trace.enabled = opts.verbose;

    const cfg = arch.load(init.gpa, init.io, opts.arch_path) catch |err|
        cli.fatal("cannot load architecture '{s}': {t}", .{ opts.arch_path, err });
    defer cfg.deinit(init.gpa);
    if (opts.verbose) cfg.print();

    // Loaded once; checked against each circuit's qubit count in compileOne.
    var asm_doc: ?assembly.Assembly = null;
    defer if (asm_doc) |a| a.deinit(init.gpa);
    if (opts.asm_path) |path| {
        asm_doc = assembly.load(init.gpa, init.io, path) catch |err|
            cli.fatal("cannot load assembly '{s}': {t}", .{ path, err });
    }

    if (opts.benchmark) {
        if (opts.out_dir) |dir| try std.Io.Dir.cwd().createDirPath(init.io, dir);
    }

    for (opts.circuits) |qasm_path| {
        // Per-circuit outputs: the --out/--bench flags for a single run,
        // paths derived from the qasm name under out_dir for a benchmark run.
        var out_path = opts.out;
        var bench_path = opts.bench;
        if (opts.benchmark) {
            out_path = null;
            bench_path = null;
            if (opts.out_dir) |dir| {
                const stem = std.fs.path.stem(qasm_path);
                out_path = try std.fmt.allocPrint(arena, "{s}/{s}.hardware.json", .{ dir, stem });
                bench_path = try std.fmt.allocPrint(arena, "{s}/{s}.bench.json", .{ dir, stem });
            }
        }
        try compileOne(init, opts, cfg, asm_doc, qasm_path, out_path, bench_path);
    }
}

fn compileOne(
    init: std.process.Init,
    opts: cli.Options,
    cfg: arch.ArchConfig,
    asm_doc: ?assembly.Assembly,
    qasm_path: []const u8,
    out_path: ?[]const u8,
    bench_path: ?[]const u8,
) !void {
    var diag: ?qasm.Diagnostic = null;
    var warnings: std.ArrayList(qasm.Diagnostic) = .empty;
    defer warnings.deinit(init.gpa);
    var circ = qasm.loadDiag(init.gpa, init.io, qasm_path, &diag, &warnings) catch |err| {
        if (diag) |d|
            cli.fatal("{s}:{d}:{d}: {t}: {s}", .{ qasm_path, d.line, d.col, err, d.reason });
        cli.fatal("cannot load circuit '{s}': {t}", .{ qasm_path, err });
    };
    defer circ.deinit();
    for (warnings.items) |w|
        std.debug.print("gatecomp: {s}:{d}:{d}: warning: {s}\n", .{ qasm_path, w.line, w.col, w.reason });

    var pipeline = try circuit.decompose(init.gpa, circ);
    defer pipeline.deinit();

    if (asm_doc) |a| {
        // The detailed diagnostic (which field disagrees) prints in check.
        assembly.check(a, cfg, pipeline.num_qubits) catch |err|
            cli.fatal("assembly '{s}' rejected: {t}", .{ opts.asm_path.?, err });
    }

    const initial_sites = if (asm_doc) |a| a.sites else null;
    const compile_start = std.Io.Clock.awake.now(init.io);
    var sch = try compiler.compile(init.gpa, &pipeline, cfg, initial_sites);
    const compile_ns: u64 = @intCast(compile_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    defer sch.deinit();

    if (builtin.mode == .Debug) try verify.verify(init.gpa, &sch);

    if (out_path) |path| {
        try serialize.writeHardware(init.gpa, init.io, path, &sch);
    }

    var metrics = bench.measure(&sch, .{});
    metrics.compile_ns = compile_ns;

    if (bench_path) |path| {
        serialize.writeBench(init.gpa, init.io, path, metrics) catch |err|
            cli.fatal("cannot write bench '{s}': {t}", .{ path, err });
    }

    if (opts.benchmark) {
        std.debug.print("gatecomp: {s}: {d} qubits, {d} frames, schedule {d:.1}us, compile {d:.2}ms\n", .{
            qasm_path,
            metrics.num_qubits,
            metrics.frames,
            metrics.totalUs(),
            @as(f64, @floatFromInt(compile_ns)) / std.time.ns_per_ms,
        });
    }

    if (opts.draw) {
        // Draw original circuit.
        try draw.pipeline(circ, null);
        // Draw circuit decomposed into stages.
        try draw.pipeline(circ, pipeline);
        // Draw arch layout and compiled schedule.
        try draw.physical(init.gpa, cfg, sch, asm_doc);
    }
}
