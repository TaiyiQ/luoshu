//! Pure precomputation shared by the visualizers: per-frame state derived
//! from a hardware schedule, plus layout geometry (trap sites, zone rects)
//! derived from the architecture — with no raylib in sight, so it is
//! unit-testable here and the render loops are pure drawing.

const std = @import("std");
const schedule = @import("schedule");
const arch = @import("arch");
const circuit = @import("circuit");
const compiler = @import("compiler");

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

// ── Dimension annotations ────────────────────────────────────────────────────

/// One CAD-style dimension for the schedule view: a double-headed arrow
/// between two feature anchors, pushed sideways into a clear lane outside
/// the traps, labeled with the physical distance it spans.
pub const Dimension = struct {
    a: Point,
    b: Point,
    /// World offset from the anchors to the arrow itself; extension lines
    /// bridge each anchor to its offset end.
    lane_nm: Point,
    label: [:0]const u8,
};

/// The spacing numbers behind the layout, anchored to the trap sites they
/// measure: per-zone trap separations, the Rydberg pair distance dr, and
/// the trap-row-to-trap-row flight gap between neighbouring zones. Labels
/// live in `arena`.
pub fn buildDimensions(arena: std.mem.Allocator, layout: arch.ArchConfig) ![]Dimension {
    var dims: std.ArrayList(Dimension) = .empty;

    const sg = layout.storage_zone.grid();
    const cg = layout.compute_zone.grid(0);
    const cg1 = layout.compute_zone.grid(1);
    const rg = layout.readout_zone.grid();

    try appendSeps(arena, &dims, sg, 0);
    // Rows 1..2, so the sep-y arrow stays clear of the dr arrow spanning
    // the paired grids at row 0.
    try appendSeps(arena, &dims, cg, 1);
    try appendSeps(arena, &dims, rg, 0);

    // Rydberg pair distance: the slm 0 and slm 1 traps at the same index.
    try appendDim(arena, &dims, "dr", .{
        .x = cg.x(0),
        .y = cg.y(0),
    }, .{
        .x = cg1.x(0),
        .y = cg1.y(0),
    }, .{ .x = -cg.sep_nm[0], .y = 0 });

    // Gaps between neighbouring zones: the flight distance between the
    // facing trap rows, not the configured zone boxes.
    try appendDim(arena, &dims, "gap", .{
        .x = sg.x(0),
        .y = sg.bottomRowY(),
    }, .{
        .x = cg.x(0),
        .y = cg.y(0),
    }, .{ .x = -sg.sep_nm[0], .y = 0 });

    const cbottom = if (cg1.bottomRowY() > cg.bottomRowY()) cg1 else cg;
    try appendDim(arena, &dims, "gap", .{
        .x = cbottom.x(0),
        .y = cbottom.bottomRowY(),
    }, .{
        .x = rg.x(0),
        .y = rg.y(0),
    }, .{ .x = -cg.sep_nm[0], .y = 0 });

    return dims.toOwnedSlice(arena);
}

/// The two trap separations of one SLM grid: sep-x between the first two
/// columns of the top row (arrow above the grid), sep-y between rows
/// `row`..`row + 1` of the first column (arrow left of the grid).
fn appendSeps(
    arena: std.mem.Allocator,
    dims: *std.ArrayList(Dimension),
    g: arch.Grid,
    row: usize,
) !void {
    if (g.num_col >= 2) {
        try appendDim(arena, dims, "", .{
            .x = g.x(0),
            .y = g.y(0),
        }, .{
            .x = g.x(1),
            .y = g.y(0),
        }, .{ .x = 0, .y = -g.sep_nm[1] });
    }
    if (g.num_row >= 2) {
        const r = if (row + 1 < g.num_row) row else 0;
        try appendDim(arena, dims, "", .{
            .x = g.x(0),
            .y = g.y(r),
        }, .{
            .x = g.x(0),
            .y = g.y(r + 1),
        }, .{ .x = -g.sep_nm[0], .y = 0 });
    }
}

fn appendDim(
    arena: std.mem.Allocator,
    dims: *std.ArrayList(Dimension),
    name: []const u8,
    a: Point,
    b: Point,
    lane_nm: Point,
) !void {
    const dx: f64 = @floatFromInt(b.x - a.x);
    const dy: f64 = @floatFromInt(b.y - a.y);
    const dist_um = @sqrt(dx * dx + dy * dy) / 1000.0;
    const label = if (name.len == 0)
        try std.fmt.allocPrintSentinel(arena, "{d:.1} um", .{dist_um}, 0)
    else
        try std.fmt.allocPrintSentinel(arena, "{s} {d:.1} um", .{ name, dist_um }, 0);
    try dims.append(arena, .{ .a = a, .b = b, .lane_nm = lane_nm, .label = label });
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

/// The logical routing product for the visualizer: one slot table per
/// routing round, in stage order — the SLM row of fixed qubits plus the
/// per-timestep AOD rows that route.Sequence.print() renders as ASCII.
/// compile frees its sequences as it schedules them, but routing is
/// deterministic, so re-running it here reproduces exactly the tables the
/// schedule was choreographed from.
pub const SlotTables = struct {
    arena: std.heap.ArenaAllocator,
    rounds: []const Round,

    pub const Round = struct {
        /// Pipeline stage this round routed; U-only stages never appear.
        stage: usize,
        /// Round index within the stage, of n_in_stage (non-bipartite
        /// stage graphs leave SLM-SLM residue for further rounds).
        ri: usize,
        n_in_stage: usize,
        /// Qubit fixed in each compute-zone SLM column, or null.
        fixed: []const ?usize,
        /// moveable[t][col] = qubit the AOD holds over `col` at timestep
        /// t, null when that column's AOD is resting. A non-null entry
        /// over an occupied SLM column is a CZ firing at t.
        moveable: []const []const ?usize,
    };

    pub fn init(gpa: std.mem.Allocator, pipe: *const circuit.Pipeline) !SlotTables {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var rounds: std.ArrayList(Round) = .empty;
        defer rounds.deinit(gpa);

        for (pipe.stages.items, 0..) |*stage, si| {
            if (stage.cz_gates.items.len == 0) continue;

            const seqs = try compiler.routeStage(gpa, stage.cz_gates.items, pipe.num_qubits, null);
            defer {
                for (seqs) |*s| s.deinit();
                gpa.free(seqs);
            }

            for (seqs, 0..) |seq, ri| {
                const rows = try alloc.alloc([]const ?usize, seq.moveable.len);
                for (seq.moveable, rows) |src, *dst| dst.* = try alloc.dupe(?usize, src);
                try rounds.append(gpa, .{
                    .stage = si,
                    .ri = ri,
                    .n_in_stage = seqs.len,
                    .fixed = try alloc.dupe(?usize, seq.fixed),
                    .moveable = rows,
                });
            }
        }

        return .{ .arena = arena, .rounds = try alloc.dupe(Round, rounds.items) };
    }

    pub fn deinit(t: *SlotTables) void {
        t.arena.deinit();
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

test "slot tables reproduce each CZ stage's gates as AOD-over-SLM pairings" {
    const gpa = std.testing.allocator;

    // h(0) makes stage 0 a U stage; the two commuting CZs merge into
    // stage 1, a path graph 0-1-2 that routes in one round.
    var c = circuit.Circuit.init(gpa, 3);
    defer c.deinit();
    try c.h(0);
    try c.cz(0, 1);
    try c.cz(1, 2);

    var pipe = try circuit.decompose(gpa, c);
    defer pipe.deinit();

    var tables = try SlotTables.init(gpa, &pipe);
    defer tables.deinit();

    try std.testing.expectEqual(@as(usize, 1), tables.rounds.len);
    const round = tables.rounds[0];
    try std.testing.expectEqual(@as(usize, 1), round.stage);
    try std.testing.expectEqual(@as(usize, 0), round.ri);
    try std.testing.expectEqual(@as(usize, 1), round.n_in_stage);

    // Every timestep row spans the same slots as the SLM row, and the
    // (AOD, SLM) pairings across all timesteps are exactly the stage's
    // CZ gates, each firing once.
    var fired = [_]usize{0} ** 9;
    for (round.moveable) |row| {
        try std.testing.expectEqual(round.fixed.len, row.len);
        for (row, round.fixed) |aod, slm| {
            const q = aod orelse continue;
            const p = slm orelse continue;
            fired[@min(p, q) * 3 + @max(p, q)] += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fired[0 * 3 + 1]);
    try std.testing.expectEqual(@as(usize, 1), fired[1 * 3 + 2]);
    var total: usize = 0;
    for (fired) |n| total += n;
    try std.testing.expectEqual(@as(usize, 2), total);
}

test "buildDimensions anchors seps, dr, and zone gaps to the example config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cfg = try arch.load(std.testing.allocator, std.testing.io, "cfg/arch.toml");
    defer cfg.deinit(std.testing.allocator);

    const dims = try buildDimensions(arena_state.allocator(), cfg);

    // sep-x + sep-y per zone, dr, and the two inter-zone gaps.
    const labels = [_][]const u8{
        "3.0 um", "3.0 um", // storage trap seps
        "10.0 um", "12.0 um", // compute site seps
        "4.0 um",    "4.0 um", // readout trap seps
        "dr 2.0 um",
        "gap 23.0 um", // storage bottom row (y=27) -> compute top row (y=50)
        "gap 20.0 um", // compute bottom row (y=160) -> readout top row (y=180)
    };
    try std.testing.expectEqual(labels.len, dims.len);
    for (dims, labels) |d, want| {
        try std.testing.expectEqualStrings(want, d.label);
    }

    // The dr arrow spans the two compute SLM grids at the same trap index.
    const dr = dims[6];
    try std.testing.expectEqual(cfg.compute_zone.grid(0).y(0), dr.a.y);
    try std.testing.expectEqual(cfg.compute_zone.grid(1).y(0), dr.b.y);

    // Arrows sit in lanes outside the grid: sep-x above, sep-y left.
    try std.testing.expect(dims[0].lane_nm.y < 0 and dims[0].lane_nm.x == 0);
    try std.testing.expect(dims[1].lane_nm.x < 0 and dims[1].lane_nm.y == 0);
}

test {
    std.testing.refAllDecls(@This());
}
