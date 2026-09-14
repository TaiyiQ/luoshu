const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const assembly = @import("assembly");
const circuit = @import("circuit");
const qasm = @import("qasm");
const compiler = @import("compiler");
const bench = @import("bench");
const viz = @import("viz");
const serialize = @import("serialize");
const trace = @import("trace");
const verify = @import("verify");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const opts = try cli.parseArgs(arena, init.io, init.minimal.args);

    trace.enabled = opts.verbose;

    const cfg = arch.load(init.gpa, init.io, opts.settings.arch) catch |err|
        cli.fatal("cannot load architecture '{s}': {t}", .{ opts.settings.arch, err });
    defer cfg.deinit(init.gpa);

    if (opts.verbose) cfg.print();

    var asm_doc: ?assembly.Assembly = null;
    defer if (asm_doc) |a| a.deinit(init.gpa);

    if (opts.settings.assembly) |path| {
        asm_doc = assembly.load(init.gpa, init.io, path) catch |err|
            cli.fatal("cannot load assembly '{s}': {t}", .{ path, err });
    }

    // Several circuits run as a suite: a metrics table instead of windows.
    const suite = opts.jobs.len > 1;

    var name_w: usize = 0;
    for (opts.jobs) |j| name_w = @max(name_w, std.fs.path.stem(j.qasm).len);

    const table = bench.Table.init(name_w);
    if (suite) table.header();

    var sum = bench.Table.Totals{};
    for (opts.jobs) |job| {
        const metrics = try compileOne(init, opts, cfg, asm_doc, job);
        if (suite) {
            table.row(std.fs.path.stem(job.qasm), metrics);
            sum.add(metrics);
        }
    }

    if (suite) table.totals(sum);
}

fn compileOne(
    init: std.process.Init,
    opts: cli.Options,
    cfg: arch.ArchConfig,
    asm_doc: ?assembly.Assembly,
    job: cli.Job,
) !bench.Metrics {
    var diag: ?qasm.Diagnostic = null;
    var warnings: std.ArrayList(qasm.Diagnostic) = .empty;
    defer warnings.deinit(init.gpa);

    var circ = qasm.loadDiag(init.gpa, init.io, job.qasm, &diag, &warnings) catch |err| {
        if (diag) |d|
            cli.fatal("{s}:{d}:{d}: {t}: {s}", .{
                job.qasm,
                d.line,
                d.col,
                err,
                d.reason,
            });
        cli.fatal("cannot load circuit '{s}': {t}", .{ job.qasm, err });
    };
    defer circ.deinit();

    for (warnings.items) |w|
        std.debug.print("luoshu: {s}:{d}:{d}: warning: {s}\n", .{
            job.qasm,
            w.line,
            w.col,
            w.reason,
        });

    var pipeline = try circuit.decompose(init.gpa, circ);
    defer pipeline.deinit();

    if (asm_doc) |a| {
        // The detailed diagnostic (which field disagrees) prints in check.
        assembly.check(a, cfg, pipeline.num_qubits) catch |err|
            cli.fatal("assembly '{s}' rejected: {t}", .{
                opts.settings.assembly.?,
                err,
            });
    }

    const initial_sites = if (asm_doc) |a| a.sites else null;
    var route_stats = compiler.RouteStats{};
    const compile_start = std.Io.Clock.awake.now(init.io);
    var sch = try compiler.compile(init.gpa, &pipeline, cfg, initial_sites, &route_stats);
    const compile_ns: u64 = @intCast(compile_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    defer sch.deinit();

    if (builtin.mode == .Debug) try verify.verify(init.gpa, &sch);

    if (job.out) |path| {
        try createParentDir(init.io, path);
        try serialize.writeHardware(init.gpa, init.io, path, &sch);
    }

    var metrics = bench.measure(&sch);
    metrics.compile_ns = compile_ns;
    metrics.cz_requested = route_stats.cz_requested;
    metrics.colors = route_stats.colors;
    metrics.max_degree = route_stats.max_degree;

    if (job.bench) |path| {
        try createParentDir(init.io, path);
        serialize.writeBench(init.gpa, init.io, path, metrics) catch |err|
            cli.fatal("cannot write bench '{s}': {t}", .{ path, err });
    }

    // Circuit, stages, logical, and schedule views as tabs in one window;
    // suite runs print the metrics table instead.
    if (opts.viz and opts.jobs.len == 1)
        try viz.run(init.gpa, sch, asm_doc, circ, pipeline);

    return metrics;
}

/// Job outputs land under the configured out directory, which may not
/// exist yet.
fn createParentDir(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
}
