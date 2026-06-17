const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const assembly = @import("assembly");
const circuit = @import("circuit");
const qasm = @import("qasm");
const compiler = @import("compiler");
const draw = @import("draw");
const serialize = @import("serialize");
const trace = @import("trace");
const verify = @import("verify");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const opts = try cli.parseArgs(init.arena.allocator(), init.minimal.args);
    trace.enabled = opts.verbose;

    var diag: ?qasm.Diagnostic = null;
    var circ = qasm.loadDiag(init.gpa, init.io, opts.qasm_path, &diag) catch |err| {
        if (diag) |d|
            cli.fatal("{s}:{d}:{d}: {t}: {s}", .{ opts.qasm_path, d.line, d.col, err, d.reason });
        cli.fatal("cannot load circuit '{s}': {t}", .{ opts.qasm_path, err });
    };
    defer circ.deinit();

    var pipeline = try circuit.decompose(init.gpa, circ);
    defer pipeline.deinit();

    const cfg = arch.load(init.gpa, init.io, opts.arch_path) catch |err|
        cli.fatal("cannot load architecture '{s}': {t}", .{ opts.arch_path, err });
    defer cfg.deinit(init.gpa);
    if (opts.verbose) cfg.print();

    var asm_doc: ?assembly.Assembly = null;
    defer if (asm_doc) |a| a.deinit(init.gpa);
    if (opts.asm_path) |path| {
        const a = assembly.load(init.gpa, init.io, path) catch |err|
            cli.fatal("cannot load assembly '{s}': {t}", .{ path, err });
        asm_doc = a;
        // The detailed diagnostic (which field disagrees) prints in check.
        assembly.check(a, cfg, pipeline.num_qubits) catch |err|
            cli.fatal("assembly '{s}' rejected: {t}", .{ path, err });
    }

    const initial_sites = if (asm_doc) |a| a.sites else null;
    var sch = try compiler.compile(init.gpa, &pipeline, cfg, initial_sites);
    defer sch.deinit();

    if (builtin.mode == .Debug) try verify.verify(init.gpa, &sch);

    if (opts.output) |path| {
        try serialize.writeHardware(init.gpa, init.io, path, &sch);
    }

    if (opts.draw) {
        // Draw original circuit.
        try draw.pipeline(circ, null);
        // Draw circuit decomposed into stages.
        try draw.pipeline(circ, pipeline);
        // Draw arch layout and compiled schedule.
        try draw.physical(init.gpa, cfg, sch);
    }
}
