const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const assembly = @import("assembly");
const circuit = @import("circuit");
const qasm = @import("qasm");
const compiler = @import("compiler");
const bench = @import("bench");
const draw = @import("draw");
const viz = @import("viz");
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

    if (opts.out_dir) |dir| try std.Io.Dir.cwd().createDirPath(init.io, dir);

    for (opts.jobs) |job| try compileOne(init, opts, cfg, asm_doc, job);
}

fn compileOne(
    init: std.process.Init,
    opts: cli.Options,
    cfg: arch.ArchConfig,
    asm_doc: ?assembly.Assembly,
    job: cli.Job,
) !void {
    var diag: ?qasm.Diagnostic = null;
    var warnings: std.ArrayList(qasm.Diagnostic) = .empty;
    defer warnings.deinit(init.gpa);
    var circ = qasm.loadDiag(init.gpa, init.io, job.qasm, &diag, &warnings) catch |err| {
        if (diag) |d|
            cli.fatal("{s}:{d}:{d}: {t}: {s}", .{ job.qasm, d.line, d.col, err, d.reason });
        cli.fatal("cannot load circuit '{s}': {t}", .{ job.qasm, err });
    };
    defer circ.deinit();
    for (warnings.items) |w|
        std.debug.print("gatecomp: {s}:{d}:{d}: warning: {s}\n", .{ job.qasm, w.line, w.col, w.reason });

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

    if (job.out) |path| {
        try serialize.writeHardware(init.gpa, init.io, path, &sch);
    }

    var metrics = bench.measure(&sch, .{});
    metrics.compile_ns = compile_ns;

    if (job.bench) |path| {
        serialize.writeBench(init.gpa, init.io, path, metrics) catch |err|
            cli.fatal("cannot write bench '{s}': {t}", .{ path, err });
    }

    if (opts.benchmark) {
        std.debug.print("gatecomp: {s}: {d} qubits, {d} frames, schedule {d:.1}us, compile {d:.2}ms\n", .{
            job.qasm,
            metrics.num_qubits,
            metrics.frames,
            metrics.totalUs(),
            @as(f64, @floatFromInt(compile_ns)) / std.time.ns_per_ms,
        });
    }

    if (opts.draw) {
        // Draw original circuit.
        try draw.pipeline(init.gpa, circ, null);
        // Draw circuit decomposed into stages.
        try draw.pipeline(init.gpa, circ, pipeline);
        // Draw arch layout and compiled schedule.
        switch (opts.viz) {
            .classic => try draw.physical(init.gpa, cfg, sch, asm_doc),
            .gui => try viz.physical(init.gpa, cfg, sch, asm_doc),
        }
    }
}
