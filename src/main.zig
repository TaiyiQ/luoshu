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

    if (opts.benchmark) printBenchHeader(opts.jobs);

    var sum = BenchTotals{};
    for (opts.jobs) |job| {
        const metrics = try compileOne(init, opts, cfg, asm_doc, job);
        if (opts.benchmark) {
            printBenchRow(opts.jobs, job, metrics);
            sum.add(metrics);
        }
    }

    if (opts.benchmark) printBenchTotals(opts.jobs, sum);
}

// --- Benchmark table -------------------------------------------------------
//
// circuit                   qubits  frames       cz    colors  cz/pulse  ...
// -------------------------------------------------------------------------
// ex/graph/graph-10-9.qasm      10      49    21/21     10/8       2.33  ...
//
// cz = pairs entangled in the schedule / CZ gates handed to routing: a
// shortfall means the router dropped gates (non-bipartite MIS leftovers).
// colors = timesteps used / max stage degree (the edge-coloring lower
// bound), both summed over stages: the gap is the coloring's slack.

/// Combined width of every column after `circuit`, including separators.
/// Keep in sync with the format strings below.
const bench_cols_width = 2 + 6 + 2 + 6 + 2 + 11 + 2 + 8 + 2 + 8 + 2 + 10 + 2 + 10 + 2 + 8 + 2 + 10;

const BenchTotals = struct {
    cz_pairs: usize = 0,
    cz_requested: usize = 0,
    colors: usize = 0,
    max_degree: usize = 0,
    shuttling_us: f64 = 0,
    loading_us: f64 = 0,
    total_us: f64 = 0,
    compile_ns: u64 = 0,

    fn add(t: *BenchTotals, m: bench.Metrics) void {
        t.cz_pairs += m.cz_pairs;
        t.cz_requested += m.cz_requested orelse 0;
        t.colors += m.colors orelse 0;
        t.max_degree += m.max_degree orelse 0;
        t.shuttling_us += m.shuttling_us;
        t.loading_us += m.loading_us;
        t.total_us += m.totalUs();
        t.compile_ns += m.compile_ns orelse 0;
    }
};

/// Widest circuit path, floored by the header label.
fn benchNameWidth(jobs: []const cli.Job) usize {
    var w: usize = "circuit".len;
    for (jobs) |j| w = @max(w, j.qasm.len);
    return w;
}

fn printBenchPadded(text: []const u8, width: usize) void {
    std.debug.print("{s}", .{text});
    for (text.len..width) |_| std.debug.print(" ", .{});
}

fn printBenchRule(jobs: []const cli.Job) void {
    for (0..benchNameWidth(jobs) + bench_cols_width) |_| std.debug.print("-", .{});
    std.debug.print("\n", .{});
}

fn printBenchHeader(jobs: []const cli.Job) void {
    printBenchPadded("circuit", benchNameWidth(jobs));
    std.debug.print("  {s:>6}  {s:>6}  {s:>11}  {s:>8}  {s:>8}  {s:>10}  {s:>10}  {s:>8}  {s:>10}\n", .{
        "qubits", "frames", "cz", "colors", "cz/pulse", "shuttle_us", "loading_us", "total_us", "compile_ms",
    });
    printBenchRule(jobs);
}

fn printBenchRow(jobs: []const cli.Job, job: cli.Job, m: bench.Metrics) void {
    var cz_buf: [32]u8 = undefined;
    var colors_buf: [32]u8 = undefined;
    const cz = std.fmt.bufPrint(&cz_buf, "{d}/{d}", .{ m.cz_pairs, m.cz_requested orelse 0 }) catch "?";
    const colors = std.fmt.bufPrint(&colors_buf, "{d}/{d}", .{ m.colors orelse 0, m.max_degree orelse 0 }) catch "?";

    printBenchPadded(job.qasm, benchNameWidth(jobs));
    std.debug.print("  {d:>6}  {d:>6}  {s:>11}  {s:>8}  {d:>8.2}  {d:>10.1}  {d:>10.1}  {d:>8.1}  {d:>10.2}\n", .{
        m.num_qubits,
        m.frames,
        cz,
        colors,
        m.avgCzPerPulse(),
        m.shuttling_us,
        m.loading_us,
        m.totalUs(),
        @as(f64, @floatFromInt(m.compile_ns orelse 0)) / std.time.ns_per_ms,
    });
}

fn printBenchTotals(jobs: []const cli.Job, sum: BenchTotals) void {
    printBenchRule(jobs);
    var buf: [32]u8 = undefined;
    var cz_buf: [32]u8 = undefined;
    var colors_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d} circuits", .{jobs.len}) catch "total";
    const cz = std.fmt.bufPrint(&cz_buf, "{d}/{d}", .{ sum.cz_pairs, sum.cz_requested }) catch "?";
    const colors = std.fmt.bufPrint(&colors_buf, "{d}/{d}", .{ sum.colors, sum.max_degree }) catch "?";

    printBenchPadded(label, benchNameWidth(jobs));
    std.debug.print("  {s:>6}  {s:>6}  {s:>11}  {s:>8}  {s:>8}  {d:>10.1}  {d:>10.1}  {d:>8.1}  {d:>10.2}\n", .{
        "",
        "",
        cz,
        colors,
        "",
        sum.shuttling_us,
        sum.loading_us,
        sum.total_us,
        @as(f64, @floatFromInt(sum.compile_ns)) / std.time.ns_per_ms,
    });
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
    var route_stats = compiler.RouteStats{};
    const compile_start = std.Io.Clock.awake.now(init.io);
    var sch = try compiler.compile(init.gpa, &pipeline, cfg, initial_sites, &route_stats);
    const compile_ns: u64 = @intCast(compile_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    defer sch.deinit();

    if (builtin.mode == .Debug) try verify.verify(init.gpa, &sch);

    if (job.out) |path| {
        try serialize.writeHardware(init.gpa, init.io, path, &sch);
    }

    var metrics = bench.measure(&sch, .{});
    metrics.compile_ns = compile_ns;
    metrics.cz_requested = route_stats.cz_requested;
    metrics.colors = route_stats.colors;
    metrics.max_degree = route_stats.max_degree;

    if (job.bench) |path| {
        serialize.writeBench(init.gpa, init.io, path, metrics) catch |err|
            cli.fatal("cannot write bench '{s}': {t}", .{ path, err });
    }

    // Circuit, stages, logical, and schedule views as tabs in one window.
    if (opts.draw) try viz.run(init.gpa, cfg, sch, asm_doc, circ, pipeline);

    return metrics;
}
