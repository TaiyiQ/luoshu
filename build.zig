const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "gatecomp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // --- Internal dependecies.

    const arch_mod = b.addModule("arch", .{
        .root_source_file = b.path("src/arch.zig"),
    });
    exe.root_module.addImport("arch", arch_mod);

    const graph_mod = b.addModule("graph", .{
        .root_source_file = b.path("src/graph.zig"),
    });
    exe.root_module.addImport("graph", graph_mod);

    const circuit_mod = b.addModule("circuit", .{
        .root_source_file = b.path("src/circuit.zig"),
    });
    exe.root_module.addImport("circuit", circuit_mod);
    circuit_mod.addImport("graph", graph_mod);

    const schedule_mod = b.addModule("schedule", .{
        .root_source_file = b.path("src/schedule.zig"),
    });
    schedule_mod.addImport("arch", arch_mod);
    exe.root_module.addImport("schedule", schedule_mod);

    const route_mod = b.addModule("route", .{
        .root_source_file = b.path("src/route.zig"),
    });
    route_mod.addImport("graph", graph_mod);
    route_mod.addImport("schedule", schedule_mod);
    exe.root_module.addImport("route", route_mod);

    const draw_mod = b.addModule("draw", .{
        .root_source_file = b.path("src/draw.zig"),
    });
    draw_mod.addImport("schedule", schedule_mod);
    draw_mod.addImport("arch", arch_mod);
    draw_mod.addImport("circuit", circuit_mod);
    exe.root_module.addImport("draw", draw_mod);

    const debug_mod = b.addModule("debug", .{
        .root_source_file = b.path("src/debug.zig"),
    });
    exe.root_module.addImport("debug", debug_mod);
    debug_mod.addImport("graph", graph_mod);
    route_mod.addImport("debug", debug_mod);

    // --- External dependecies.

    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("toml", toml_dep.module("toml"));

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .Wayland,
    });
    exe.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    draw_mod.addImport("raylib", raylib_dep.module("raylib"));
    circuit_mod.addImport("raylib", raylib_dep.module("raylib"));
    circuit_mod.addImport("raygui", raylib_dep.module("raygui"));

    b.installArtifact(exe); // enables `zig build`

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args); // pass -- args through

    const run_step = b.step("run", "Run gatecomp"); // enables `zig build run`
    run_step.dependOn(&run_cmd.step);
}
