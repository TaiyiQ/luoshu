const std = @import("std");
const builtin = @import("builtin");
const core = @import("graph");

const enabled = builtin.mode == .Debug;

pub fn edgeColors(g: core.Graph) void {
    if (comptime !enabled) return;
    std.debug.print(">> Edge Colors\n", .{});

    for (0..g.n) |x| {
        var has_any = false;

        var e = g.edges[x];
        while (e) |edge| : (e = edge.next) {
            const y = edge.y;
            if (x < y) {
                if (edge.color) |c| {
                    if (!has_any) {
                        std.debug.print("  {d} -> ", .{x});
                        has_any = true;
                    }
                    std.debug.print("{d}:{d} ", .{ y, c });
                }
            }
        }

        if (has_any) std.debug.print("\n", .{});
    }
}

pub fn aodTargets(g: *core.Graph, aod_order: []const usize, aod_targets: [][]usize) void {
    if (comptime !enabled) return;
    std.debug.print(">> AOD Target Positions\n", .{});

    for (1..aod_targets.len) |c| {
        const targets = aod_targets[c];
        std.debug.print("Color {d} (parallel CZ layer):\n", .{c});

        var shift: usize = 0;

        for (aod_order, 0..) |aod_id, i| {
            var partner: ?usize = null;

            var e = g.edges[aod_id];
            while (e) |edge| : (e = edge.next) {
                if (edge.color == c) {
                    partner = edge.y;
                    break;
                }
            }

            const target = targets[i];
            if (partner) |p| {
                std.debug.print("  AOD {d} (qubit {d}) -> ACTIVE partner {d} | column {d} (shift={d})\n", .{ i, aod_id, p, target, shift });
            } else {
                std.debug.print("  AOD {d} (qubit {d}) -> RESTING          | column {d} (shift={d} -> {d})\n", .{ i, aod_id, target, shift, shift + 1 });
                shift += 1;
            }
        }
    }
}

pub fn qubitPositions(
    time_step: usize,
    aod_order: []const usize,
    slm_order: []const usize,
    match: []const ?usize,
    fixed_slm_slots: []const usize,
    aod_slot: []const usize,
) void {
    if (comptime !enabled) return;
    std.debug.print("\n=== Resting Positions Debug — Time Step t = {} (SLMs FIXED) ===\n", .{time_step});
    std.debug.print("AOD order : ", .{});
    for (aod_order) |id| std.debug.print("AOD{d} ", .{id});
    std.debug.print("\nMatching  : ", .{});
    for (match) |m| {
        if (m) |v| std.debug.print("SLM{d} ", .{v}) else std.debug.print("null ", .{});
    }
    std.debug.print("\n\nFIXED SLM layout (never changes):\n", .{});
    for (slm_order, 0..) |slm_id, i| {
        std.debug.print("  SLM {d:2} → slot {d}\n", .{ slm_id, fixed_slm_slots[i] });
    }

    var max_slot: usize = 0;
    for (fixed_slm_slots) |s| max_slot = @max(max_slot, s);
    for (aod_slot) |s| max_slot = @max(max_slot, s);

    std.debug.print("\nTrap layout this step:\n", .{});
    std.debug.print("────────────────────────────────────\n", .{});
    for (0..max_slot + 1) |slot| {
        std.debug.print("Slot {d:2} → ", .{slot});
        var printed = false;

        for (slm_order, 0..) |slm_id, i| {
            if (fixed_slm_slots[i] == slot) {
                std.debug.print("SLM{d} (FIXED)", .{slm_id});
                printed = true;
                break;
            }
        }

        if (!printed) {
            for (aod_order, 0..) |aod_id, i| {
                if (aod_slot[i] == slot) {
                    if (match[i]) |slm_id| {
                        std.debug.print("AOD{d} ↔ SLM{d}", .{ aod_id, slm_id });
                    } else {
                        std.debug.print("AOD{d} (RESTING GAP)", .{aod_id});
                    }
                    printed = true;
                    break;
                }
            }
        }

        if (!printed) std.debug.print("(empty)", .{});
        std.debug.print("\n", .{});
    }
    std.debug.print("────────────────────────────────────\nTotal slots used: {d}\n====================================\n\n", .{max_slot + 1});
}
