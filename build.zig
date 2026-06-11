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
        .target = target,
    });
    exe.root_module.addImport("arch", arch_mod);

    const circuit_mod = b.addModule("circuit", .{
        .root_source_file = b.path("src/circuit.zig"),
        .target = target,
    });
    exe.root_module.addImport("circuit", circuit_mod);

    const schedule_mod = b.addModule("schedule", .{
        .root_source_file = b.path("src/schedule.zig"),
        .target = target,
    });
    schedule_mod.addImport("arch", arch_mod);
    schedule_mod.addImport("circuit", circuit_mod);
    exe.root_module.addImport("schedule", schedule_mod);

    const route_mod = b.addModule("route", .{
        .root_source_file = b.path("src/route.zig"),
        .target = target,
    });
    route_mod.addImport("schedule", schedule_mod);
    exe.root_module.addImport("route", route_mod);
    circuit_mod.addImport("arch", arch_mod);
    circuit_mod.addImport("schedule", schedule_mod);
    circuit_mod.addImport("route", route_mod);

    const serialize_mod = b.addModule("serialize", .{
        .root_source_file = b.path("src/serialize.zig"),
        .target = target,
    });
    serialize_mod.addImport("schedule", schedule_mod);
    exe.root_module.addImport("serialize", serialize_mod);
    circuit_mod.addImport("serialize", serialize_mod);
    route_mod.addImport("serialize", serialize_mod); // for snapshot.zig (route's test helper)

    const verify_mod = b.addModule("verify", .{
        .root_source_file = b.path("src/verify.zig"),
        .target = target,
    });
    verify_mod.addImport("schedule", schedule_mod);
    verify_mod.addImport("arch", arch_mod);
    exe.root_module.addImport("verify", verify_mod);

    // Test-only helper (refAllDeclsRecursive). A named module because a file
    // may belong to only one module, so per-module file imports won't do.
    const testutil_mod = b.createModule(.{
        .root_source_file = b.path("src/testutil.zig"),
        .target = target,
    });
    arch_mod.addImport("testutil", testutil_mod);
    circuit_mod.addImport("testutil", testutil_mod);
    schedule_mod.addImport("testutil", testutil_mod);
    route_mod.addImport("testutil", testutil_mod);
    serialize_mod.addImport("testutil", testutil_mod);
    verify_mod.addImport("testutil", testutil_mod);

    // Golden tests over the full pipeline: circuit -> Sequence/Hardware JSON,
    // compared byte-for-byte against testdata/ snapshots.
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/golden.zig"),
        .target = target,
    });
    golden_mod.addImport("arch", arch_mod);
    golden_mod.addImport("circuit", circuit_mod);
    golden_mod.addImport("schedule", schedule_mod);
    golden_mod.addImport("serialize", serialize_mod);
    golden_mod.addImport("verify", verify_mod);
    golden_mod.addImport("testutil", testutil_mod);

    const draw_mod = b.addModule("draw", .{
        .root_source_file = b.path("src/draw.zig"),
        .target = target,
    });
    draw_mod.addImport("schedule", schedule_mod);
    draw_mod.addImport("arch", arch_mod);
    draw_mod.addImport("circuit", circuit_mod);
    exe.root_module.addImport("draw", draw_mod);

    // --- External dependecies.

    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    arch_mod.addImport("toml", toml_dep.module("toml"));

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

    // --- Tests: `zig build test`.
    // draw is excluded: testing it would link raylib; it is still compiled by
    // the exe build. Every other module carries a refAllDeclsRecursive test,
    // so dead code fails the build instead of bit-rotting.

    const test_step = b.step("test", "Run unit and golden tests");
    const test_mods = [_]*std.Build.Module{
        arch_mod, circuit_mod, schedule_mod, route_mod, serialize_mod, verify_mod, golden_mod,
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
    update_exe.root_module.addImport("circuit", circuit_mod);
    update_exe.root_module.addImport("route", route_mod);
    update_exe.root_module.addImport("serialize", serialize_mod);
    update_exe.root_module.addImport("verify", verify_mod);
    update_exe.root_module.addImport("golden", golden_mod);

    const update_run = b.addRunArtifact(update_exe);
    update_run.setCwd(b.path("."));
    const update_step = b.step("update-snapshots", "Regenerate golden snapshots in testdata/");
    update_step.dependOn(&update_run.step);
}
