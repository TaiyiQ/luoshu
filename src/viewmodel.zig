//! Pure per-frame precomputation over a hardware schedule.
//! Everything draw.zig needs that is a function of the
//! schedule alone, with no raylib in sight — so it is unit-testable here
//! and the render loop is pure drawing.

const std = @import("std");
const schedule = @import("schedule");

const Point = schedule.Point;

/// Op counts across the whole schedule, shown in the HUD panel.
pub const Summary = struct {
    move: u32 = 0,
    raman: u32 = 0,
    rydberg: u32 = 0,
    measure: u32 = 0,
};

pub const ViewModel = struct {
    gpa: std.mem.Allocator,

    /// positions[t][q] = settled position of qubit q at the end of frame t.
    positions: [][]Point,

    /// loaded[t][q] = whether qubit q is held in the AOD at the end of frame t.
    loaded: [][]bool,

    /// Highest qubit id referenced by any op, plus one.
    num_qubits: usize,

    summary: Summary,

    pub fn init(gpa: std.mem.Allocator, hw: *const schedule.Hardware) !ViewModel {
        const frame_count = hw.frames.items.len;

        var vm = ViewModel{
            .gpa = gpa,
            .positions = try gpa.alloc([]Point, frame_count),
            .loaded = try gpa.alloc([]bool, frame_count),
            .num_qubits = 0,
            .summary = .{},
        };

        // Partial-failure cleanup: mark what is not yet allocated.
        for (vm.positions) |*p| p.* = &.{};
        for (vm.loaded) |*l| l.* = &.{};
        errdefer vm.deinit();

        const cur_pos = try gpa.dupe(Point, hw.initial);
        defer gpa.free(cur_pos);

        const cur_loaded = try gpa.alloc(bool, hw.placement.len);
        defer gpa.free(cur_loaded);
        @memset(cur_loaded, false);

        for (hw.frames.items, 0..) |frame, t| {
            for (frame.items) |op| {
                switch (op) {
                    .move => |m| {
                        cur_pos[m.qubit] = m.dest;
                        vm.summary.move += 1;
                        vm.bump(m.qubit);
                    },
                    .load => |ld| {
                        cur_loaded[ld.qubit] = true;
                        vm.bump(ld.qubit);
                    },
                    .store => |st| {
                        cur_loaded[st.qubit] = false;
                        vm.bump(st.qubit);
                    },
                    .raman => |r| {
                        vm.summary.raman += 1;
                        for (r.targets) |target| vm.bump(target.qubit);
                    },
                    .rydberg => vm.summary.rydberg += 1,
                    .measure => |m| {
                        vm.summary.measure += 1;
                        for (m.qubits) |q| vm.bump(q);
                    },
                }
            }

            vm.positions[t] = try gpa.dupe(Point, cur_pos);
            vm.loaded[t] = try gpa.dupe(bool, cur_loaded);
        }

        return vm;
    }

    pub fn deinit(vm: *ViewModel) void {
        for (vm.positions) |p| vm.gpa.free(p);
        vm.gpa.free(vm.positions);

        for (vm.loaded) |l| vm.gpa.free(l);
        vm.gpa.free(vm.loaded);
    }

    fn bump(vm: *ViewModel, qubit: u32) void {
        vm.num_qubits = @max(vm.num_qubits, qubit + 1);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const arch = @import("arch");

var test_no_slms: [0]arch.Slm = .{};

fn testHw(gpa: std.mem.Allocator, initial: []const Point) !schedule.Hardware {
    const slm = arch.Slm{
        .slm_id = 0,
        .num_row = 1,
        .num_col = 4,
        .sep_nm = .{ 1000, 1000 },
        .offset_nm = .{ 0, 0 },
    };

    var hw = schedule.Hardware{
        .gpa = gpa,
        .arena = .init(gpa),
        .cfg = .{
            .platform = .{
                .name = "test",
                .version = "0",
            },
            .aod = .{
                .aod_id = 0,
                .min_sep_nm = 100,
                .max_num_row = 4,
                .max_num_col = 4,
            },
            .storage_zone = .{
                .zone_id = 0,
                .offset_nm = .{ 0, 0 },
                .dimension_nm = .{ 4000, 1000 },
                .slm = slm,
            },
            .compute_zone = .{
                .zone_id = 1,
                .offset_nm = .{ 0, 5000 },
                .dimension_nm = .{ 4000, 1000 },
                .dr_nm = 200,
                .dw_nm = 1000,
                .slms = &test_no_slms,
            },
            .readout_zone = .{
                .zone_id = 2,
                .offset_nm = .{ 0, 9000 },
                .dimension_nm = .{ 4000, 1000 },
                .slm = slm,
            },
            .constraints = .{
                .db_nm = 300,
                .dz_nm = 100,
                .one_qubit_gate_fidelity = 1,
                .two_qubit_gate_fidelity = 1,
                .readout_fidelity = 1,
            },
        },
    };

    const a = hw.arena.allocator();

    hw.initial = try a.dupe(Point, initial);

    hw.placement = try a.alloc(schedule.Atom, initial.len);

    for (hw.placement, initial, 0..) |*p, pos, i| {
        p.* = .{ .id = @intCast(i), .pos = pos };
    }

    return hw;
}

fn addFrame(hw: *schedule.Hardware, kinds: []const schedule.OpKind) !void {
    const a = hw.arena.allocator();
    var frame: schedule.Frame = .empty;
    try frame.appendSlice(a, kinds);
    try hw.frames.append(a, frame);
}

fn pt(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}

test "positions track moves and loaded is monotone between load and store" {
    const gpa = std.testing.allocator;

    var hw = try testHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 0),
                .dest = pt(0, 500),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 500),
                .dest = pt(2000, 500),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .store = .{
                .qubit = 0,
                .position = pt(2000, 500),
            },
        },
    });

    var vm = try ViewModel.init(gpa, &hw);
    defer vm.deinit();

    // Loaded from the load frame through the frame before the store.
    const expected_loaded = [_]bool{ true, true, true, false };
    for (vm.loaded, expected_loaded) |frame_loaded, want| {
        try std.testing.expectEqual(want, frame_loaded[0]);
        try std.testing.expectEqual(false, frame_loaded[1]); // never loaded
    }

    // Positions settle to each frame's move destination; qubit 1 never moves.
    const expected_pos = [_]Point{
        pt(0, 0),
        pt(0, 500),
        pt(2000, 500),
        pt(2000, 500),
    };
    for (vm.positions, expected_pos) |frame_pos, want| {
        try std.testing.expectEqual(want, frame_pos[0]);
        try std.testing.expectEqual(pt(1000, 0), frame_pos[1]);
    }

    try std.testing.expectEqual(@as(usize, 1), vm.num_qubits);
    try std.testing.expectEqual(@as(u32, 2), vm.summary.move);
}

test "summary counts ops and num_qubits spans all op kinds" {
    const gpa = std.testing.allocator;

    var hw = try testHw(gpa, &.{ pt(0, 0), pt(1000, 0), pt(2000, 0) });
    defer hw.deinit();

    const a = hw.arena.allocator();

    const targets = try a.dupe(schedule.RamanTarget, &.{
        .{
            .qubit = 1,
            .pos = pt(1000, 0),
        },
    });
    const qubits = try a.dupe(u32, &.{ 0, 1, 2 });

    try addFrame(&hw, &.{
        .{
            .raman = .{
                .angle = 0.5,
                .phase = 0,
                .targets = targets,
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .rydberg = .{
                .zone = .compute,
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .measure = .{
                .zone = .storage,
                .qubits = qubits,
            },
        },
    });

    var vm = try ViewModel.init(gpa, &hw);
    defer vm.deinit();

    try std.testing.expectEqual(
        Summary{
            .raman = 1,
            .rydberg = 1,
            .measure = 1,
        },
        vm.summary,
    );

    try std.testing.expectEqual(@as(usize, 3), vm.num_qubits);
}

test {
    std.testing.refAllDecls(@This());
}
