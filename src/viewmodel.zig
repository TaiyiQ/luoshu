//! Pure precomputation shared by the visualizers: per-frame state derived
//! from a hardware schedule, plus layout geometry (trap sites, zone rects)
//! derived from the architecture — with no raylib in sight, so it is
//! unit-testable here and the render loops are pure drawing.

const std = @import("std");
const schedule = @import("schedule");
const arch = @import("arch");
const circuit = @import("circuit");

const Point = schedule.Point;

/// Enumerate every SLM trap site across storage, compute, and readout
/// zones. Drawn as background indicators in the visualization.
pub fn allSlmSites(gpa: std.mem.Allocator, layout: arch.ArchConfig) ![]const Point {
    var sites: std.ArrayList(Point) = .empty;

    try appendSlmSites(gpa, &sites, layout.storage_zone.offset_nm, layout.storage_zone.slm);
    for (layout.compute_zone.slms) |slm| {
        try appendSlmSites(gpa, &sites, layout.compute_zone.offset_nm, slm);
    }
    try appendSlmSites(gpa, &sites, layout.readout_zone.offset_nm, layout.readout_zone.slm);

    return try sites.toOwnedSlice(gpa);
}

fn appendSlmSites(
    gpa: std.mem.Allocator,
    sites: *std.ArrayList(Point),
    zone_offset_nm: [2]i32,
    slm: arch.Slm,
) !void {
    const x0 = zone_offset_nm[0] + slm.offset_nm[0];
    const y0 = zone_offset_nm[1] + slm.offset_nm[1];
    const x_sep: i32 = @intCast(slm.sep_nm[0]);
    const y_sep: i32 = @intCast(slm.sep_nm[1]);
    for (0..slm.num_row) |ri| for (0..slm.num_col) |ci| {
        try sites.append(gpa, .{
            .x = x0 + @as(i32, @intCast(ci)) * x_sep,
            .y = y0 + @as(i32, @intCast(ri)) * y_sep,
        });
    };
}

/// One zone's SLM grid extent in world nm, padded by half a trap separation.
pub const ZoneRect = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

pub fn slmZoneRect(zone_ox: i32, zone_oy: i32, slm: arch.Slm) ZoneRect {
    const pad_x: i32 = @intCast(slm.sep_nm[0] / 2);
    const pad_y: i32 = @intCast(slm.sep_nm[1] / 2);
    const x0 = zone_ox + slm.offset_nm[0] - pad_x;
    const y0 = zone_oy + slm.offset_nm[1] - pad_y;
    const x1 = x0 + @as(i32, @intCast((slm.num_col - 1) * slm.sep_nm[0])) + 2 * pad_x;
    const y1 = y0 + @as(i32, @intCast((slm.num_row - 1) * slm.sep_nm[1])) + 2 * pad_y;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

/// One gate with the diagram column the layout pass assigned it.
pub const LaidGate = struct { gate: circuit.Native, col: usize };

/// Column layout for the circuit diagrams: each gate takes the leftmost
/// column free on every wire it touches (a CZ blocks its whole
/// control..target span, keeping its connector clear), so gates on disjoint
/// wires share a column instead of staggering. With a pipeline, a stage
/// starts past its predecessor's columns, so stages never share one.
pub const CircuitLayout = struct {
    gpa: std.mem.Allocator,
    laid: []LaidGate,
    /// Each stage's first column; empty when laid out flat (no pipeline).
    stage_cols: []usize,
    n_cols: usize,
    num_qubits: usize,

    pub fn init(gpa: std.mem.Allocator, c: circuit.Circuit, p: ?circuit.Pipeline) !CircuitLayout {
        var laid: std.ArrayList(LaidGate) = .empty;
        defer laid.deinit(gpa);
        var stage_cols: std.ArrayList(usize) = .empty;
        defer stage_cols.deinit(gpa);

        const next_free = try gpa.alloc(usize, c.n);
        defer gpa.free(next_free);
        @memset(next_free, 0);

        var n_cols: usize = 0;
        if (p) |pipe| {
            for (pipe.stages.items) |stage| {
                try stage_cols.append(gpa, n_cols);
                @memset(next_free, n_cols);
                for (stage.cz_gates.items) |g| {
                    n_cols = @max(n_cols, try place(gpa, &laid, next_free, .{ .cz = g }));
                }
                for (stage.u_gates.items) |g| {
                    n_cols = @max(n_cols, try place(gpa, &laid, next_free, .{ .u = g }));
                }
            }
        } else {
            for (c.gates.items) |gate| {
                n_cols = @max(n_cols, try place(gpa, &laid, next_free, gate));
            }
        }

        const laid_owned = try laid.toOwnedSlice(gpa);
        errdefer gpa.free(laid_owned);
        return .{
            .gpa = gpa,
            .laid = laid_owned,
            .stage_cols = try stage_cols.toOwnedSlice(gpa),
            .n_cols = n_cols,
            .num_qubits = c.n,
        };
    }

    pub fn deinit(l: *CircuitLayout) void {
        l.gpa.free(l.laid);
        l.gpa.free(l.stage_cols);
    }

    // Place one gate at the leftmost column free on every wire it touches
    // and advance those wires past it. Returns the columns used so far.
    fn place(
        gpa: std.mem.Allocator,
        laid: *std.ArrayList(LaidGate),
        next_free: []usize,
        gate: circuit.Native,
    ) !usize {
        const span: [2]usize = switch (gate) {
            .u => |g| .{ g.qubit, g.qubit },
            .cz => |g| .{ @min(g.control, g.target), @max(g.control, g.target) },
            .reset => |g| .{ g.qubit, g.qubit },
        };
        var col: usize = 0;
        for (next_free[span[0] .. span[1] + 1]) |f| col = @max(col, f);
        @memset(next_free[span[0] .. span[1] + 1], col + 1);
        try laid.append(gpa, .{ .gate = gate, .col = col });
        return col + 1;
    }
};

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

test "flat layout: disjoint gates share a column, a CZ blocks its span" {
    const gpa = std.testing.allocator;

    var c = circuit.Circuit.init(gpa, 4);
    defer c.deinit();
    try c.cz(0, 2); // spans wires 0..2
    try c.z(1); // inside the CZ span: pushed to column 1
    try c.z(3); // outside the span: shares column 0

    var lay = try CircuitLayout.init(gpa, c, null);
    defer lay.deinit();

    try std.testing.expectEqual(@as(usize, 2), lay.n_cols);
    try std.testing.expectEqual(@as(usize, 0), lay.stage_cols.len);
    try std.testing.expectEqual(@as(usize, 3), lay.laid.len);
    try std.testing.expectEqual(@as(usize, 0), lay.laid[0].col); // cz
    try std.testing.expectEqual(@as(usize, 1), lay.laid[1].col); // z(1)
    try std.testing.expectEqual(@as(usize, 0), lay.laid[2].col); // z(3)
}

test "staged layout: stages never share a column" {
    const gpa = std.testing.allocator;

    var c = circuit.Circuit.init(gpa, 2);
    defer c.deinit();
    try c.cz(0, 1);
    try c.h(1); // U barrier: homogeneous staging splits into its own stage
    try c.cz(0, 1);

    var pipe = try circuit.decompose(gpa, c);
    defer pipe.deinit();
    // [cz(0,1)], [h(1)], [cz(0,1)] — stages alternate CZ/U kind, so the U
    // barrier can't share a stage with either CZ.
    try std.testing.expectEqual(@as(usize, 3), pipe.stages.items.len);

    var lay = try CircuitLayout.init(gpa, c, pipe);
    defer lay.deinit();

    try std.testing.expectEqual(@as(usize, 3), lay.stage_cols.len);
    // Each stage starts past every column the previous one used.
    for (lay.stage_cols[1..], lay.stage_cols[0 .. lay.stage_cols.len - 1]) |sc, prev| {
        try std.testing.expect(sc > prev);
    }
    for (lay.laid) |lg| {
        try std.testing.expect(lg.col < lay.n_cols);
    }
    // The layout preserves stage grouping: within a stage CZs come first,
    // so the second CZ sits at or past the last stage's first column.
    const last = lay.laid[lay.laid.len - 1];
    try std.testing.expect(last.gate == .cz);
    try std.testing.expect(last.col >= lay.stage_cols[2]);
}

test {
    std.testing.refAllDecls(@This());
}
