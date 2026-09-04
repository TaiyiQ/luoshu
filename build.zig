const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "luoshu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // --- Internal dependecies. The module graph mirrors the pass pipeline:
    // circuit (front-end) and route depend only on std; schedule depends on
    // arch; compiler is the driver that orchestrates all of them.

    const settings_mod = b.addModule("settings", .{
        .root_source_file = b.path("src/settings.zig"),
        .target = target,
    });

    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
    });
    cli_mod.addImport("settings", settings_mod);
    exe.root_module.addImport("cli", cli_mod);

    const arch_mod = b.addModule("arch", .{
        .root_source_file = b.path("src/architecture.zig"),
        .target = target,
    });
    exe.root_module.addImport("arch", arch_mod);

    const circuit_mod = b.addModule("circuit", .{
        .root_source_file = b.path("src/circuit.zig"),
        .target = target,
    });
    exe.root_module.addImport("circuit", circuit_mod);

    // OpenQASM front-end: parses .qasm text into a circuit.Circuit.
    const qasm_mod = b.addModule("qasm", .{
        .root_source_file = b.path("src/qasm.zig"),
        .target = target,
    });
    qasm_mod.addImport("circuit", circuit_mod);
    exe.root_module.addImport("qasm", qasm_mod);

    const schedule_mod = b.addModule("schedule", .{
        .root_source_file = b.path("src/schedule.zig"),
        .target = target,
    });
    schedule_mod.addImport("arch", arch_mod);

    // Schedule metrics + timing model (NALAC-style benchmarking).
    const bench_mod = b.addModule("bench", .{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
    });
    bench_mod.addImport("schedule", schedule_mod);
    exe.root_module.addImport("bench", bench_mod);

    // Upstream atom-rearrangement handoff: storage occupancy JSON -> Sites.
    const assembly_mod = b.addModule("assembly", .{
        .root_source_file = b.path("src/assembly.zig"),
        .target = target,
    });
    assembly_mod.addImport("schedule", schedule_mod);
    assembly_mod.addImport("arch", arch_mod);
    exe.root_module.addImport("assembly", assembly_mod);

    // Pass tracing, silent unless the driver enables it (-v). Also the home
    // of the shared "quiet-suppressible diagnostic print" helper used by
    // arch/assembly/verify's validation checks.
    const trace_mod = b.addModule("trace", .{
        .root_source_file = b.path("src/trace.zig"),
        .target = target,
    });
    exe.root_module.addImport("trace", trace_mod);
    arch_mod.addImport("trace", trace_mod);
    assembly_mod.addImport("trace", trace_mod);

    const rest_mod = b.addModule("resting", .{
        .root_source_file = b.path("src/resting.zig"),
        .target = target,
    });
    rest_mod.addImport("trace", trace_mod);
    exe.root_module.addImport("resting", rest_mod);

    const graph_mod = b.addModule("graph", .{
        .root_source_file = b.path("src/graph.zig"),
        .target = target,
    });
    graph_mod.addImport("graph", graph_mod);
    graph_mod.addImport("trace", trace_mod);

    const color_mod = b.addModule("color", .{
        .root_source_file = b.path("src/color.zig"),
        .target = target,
    });
    color_mod.addImport("color", color_mod);
    color_mod.addImport("graph", graph_mod);

    const route_mod = b.addModule("route", .{
        .root_source_file = b.path("src/route.zig"),
        .target = target,
    });
    route_mod.addImport("trace", trace_mod);
    route_mod.addImport("resting", rest_mod);
    route_mod.addImport("graph", graph_mod);
    route_mod.addImport("color", color_mod);

    const serialize_mod = b.addModule("serialize", .{
        .root_source_file = b.path("src/serialize.zig"),
        .target = target,
    });
    serialize_mod.addImport("arch", arch_mod);
    serialize_mod.addImport("schedule", schedule_mod);
    serialize_mod.addImport("bench", bench_mod);
    exe.root_module.addImport("serialize", serialize_mod);
    route_mod.addImport("serialize", serialize_mod); // route's snapshot tests

    const compiler_mod = b.addModule("compiler", .{
        .root_source_file = b.path("src/compiler.zig"),
        .target = target,
    });
    compiler_mod.addImport("arch", arch_mod);
    compiler_mod.addImport("circuit", circuit_mod);
    compiler_mod.addImport("route", route_mod);
    compiler_mod.addImport("schedule", schedule_mod);
    compiler_mod.addImport("graph", graph_mod);
    exe.root_module.addImport("compiler", compiler_mod);

    const verify_mod = b.addModule("verify", .{
        .root_source_file = b.path("src/verify.zig"),
        .target = target,
    });
    verify_mod.addImport("schedule", schedule_mod);
    verify_mod.addImport("arch", arch_mod);
    verify_mod.addImport("trace", trace_mod);
    exe.root_module.addImport("verify", verify_mod);

    // Golden tests over the full pipeline: verify + CZ coverage per case,
    // bench metrics against testdata/metrics.json.
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/golden.zig"),
        .target = target,
    });
    golden_mod.addImport("arch", arch_mod);
    golden_mod.addImport("assembly", assembly_mod);
    golden_mod.addImport("bench", bench_mod);
    golden_mod.addImport("circuit", circuit_mod);
    golden_mod.addImport("qasm", qasm_mod);
    golden_mod.addImport("compiler", compiler_mod);
    golden_mod.addImport("schedule", schedule_mod);
    golden_mod.addImport("serialize", serialize_mod);
    golden_mod.addImport("verify", verify_mod);

    // viz's raylib-free precompute, split out so it is unit-testable.
    const viewmodel_mod = b.addModule("viewmodel", .{
        .root_source_file = b.path("src/viewmodel.zig"),
        .target = target,
    });
    viewmodel_mod.addImport("schedule", schedule_mod);
    viewmodel_mod.addImport("arch", arch_mod);
    viewmodel_mod.addImport("circuit", circuit_mod);
    // For SlotTables: the logical view re-runs routing (deterministic)
    // rather than threading capture through the compile.
    viewmodel_mod.addImport("compiler", compiler_mod);

    // raygui-based visualizer: one window hosting the circuit, stage,
    // logical, and schedule views as tabs.
    const viz_mod = b.addModule("viz", .{
        .root_source_file = b.path("src/viz/viz.zig"),
        .target = target,
    });
    viz_mod.addImport("schedule", schedule_mod);
    viz_mod.addImport("arch", arch_mod);
    viz_mod.addImport("assembly", assembly_mod);
    viz_mod.addImport("circuit", circuit_mod);
    viz_mod.addImport("viewmodel", viewmodel_mod);
    exe.root_module.addImport("viz", viz_mod);

    // --- External dependecies.

    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    arch_mod.addImport("toml", toml_dep.module("toml"));
    settings_mod.addImport("toml", toml_dep.module("toml"));

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .Wayland,
    });
    exe.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    viz_mod.addImport("raylib", raylib_dep.module("raylib"));
    viz_mod.addImport("raygui", raylib_dep.module("raygui"));

    b.installArtifact(exe); // enables `zig build`

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args); // pass -- args through

    const run_step = b.step("run", "Run luoshu"); // enables `zig build run`
    run_step.dependOn(&run_cmd.step);

    // --- Tests: `zig build test`.
    // viz is excluded: testing it would link raylib; it is still compiled
    // by the exe build. Every other module carries a
    // std.testing.refAllDecls test, so dead code fails the build instead of
    // bit-rotting.

    const test_step = b.step("test", "Run unit and golden tests");
    const test_mods = [_]*std.Build.Module{
        arch_mod, assembly_mod, settings_mod, trace_mod, circuit_mod, qasm_mod, schedule_mod, bench_mod, rest_mod, color_mod, route_mod, compiler_mod, serialize_mod, verify_mod, viewmodel_mod, golden_mod,
    };
    for (test_mods) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        run_t.setCwd(b.path(".")); // snapshot tests read testdata/ relative to repo root
        test_step.dependOn(&run_t.step);
    }

    // --- Snapshot regeneration: `zig build update-snapshots`.

    const update_exe = b.addExecutable(.{
        .name = "update-snapshots",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/update_snapshots.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    update_exe.root_module.addImport("arch", arch_mod);
    update_exe.root_module.addImport("route", route_mod);
    update_exe.root_module.addImport("serialize", serialize_mod);
    update_exe.root_module.addImport("golden", golden_mod);

    const update_run = b.addRunArtifact(update_exe);
    update_run.setCwd(b.path("."));
    const update_step = b.step("update-snapshots", "Regenerate golden snapshots in testdata/");
    update_step.dependOn(&update_run.step);
}
