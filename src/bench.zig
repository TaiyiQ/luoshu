//! Timing model and schedule metrics for benchmarking, following the
//! evaluation methodology of NALAC (Stade et al., arXiv:2405.08068): the cost
//! of a zoned neutral-atom schedule is dominated by *routing overhead* —
//! loading/storing atoms into the AOD and shuttling them between zones — not by
//! the gate pulses themselves.
//!
//! The schedule already encodes parallelism: every op in one Hardware.Frame
//! executes simultaneously (the AOD translates all its atoms at once, the
//! Rydberg laser fires one global pulse). So a frame's wall-clock duration is
//!
//!     max(move distance in frame) / shuttle_speed
//!       + (20 µs if the frame picks atoms up)
//!       + (20 µs if the frame drops atoms)
//!       + (0.2 µs if the frame fires an entangling pulse)
//!
//! and the schedule's runtime is the sum over frames. A naive (serialized)
//! router produces many more frames for the same circuit, so this rewards the
//! parallelism the compiler achieves — exactly the comparison NALAC reports.

const std = @import("std");
const schedule = @import("schedule");

/// Physical timing constants, NALAC's (arXiv:2405.08068, §V): shuttle
/// 0.55 µm/µs, load/store 20 µs each, CZ pulse 0.2 µs. Serialized under
/// `timing_model` in bench JSON so the numbers stay self-describing.
pub const Timing = struct {
    /// AOD transport speed, nm per µs (NALAC: 0.55 µm/µs = 550 nm/µs).
    pub const shuttle_nm_per_us: f64 = 550.0;

    /// AOD pick-up time (trap ramp-on), µs.
    pub const load_us: f64 = 20.0;

    /// SLM drop time (trap hand-off), µs.
    pub const store_us: f64 = 20.0;

    /// Rydberg/CZ entangling pulse, µs.
    pub const rydberg_us: f64 = 0.2;

    /// Single-qubit Raman pulse, µs. NALAC does not model 1Q gate time; 0
    /// keeps the reported total comparable to the paper.
    pub const raman_us: f64 = 0.0;
};

/// Aggregate metrics for one compiled schedule. Times are in µs.
pub const Metrics = struct {
    num_qubits: usize,

    /// Schedule depth: number of parallel timesteps (Hardware frames).
    frames: usize,

    n_load: usize = 0,
    n_store: usize = 0,
    n_move: usize = 0,

    /// Entangling pulses fired (one per occupied compute timeframe).
    n_rydberg: usize = 0,

    /// Single-qubit gates applied.
    n_raman: usize = 0,

    n_measure: usize = 0,

    /// CZ pairs entangled across all pulses (sum of pairs per pulse).
    cz_pairs: usize = 0,

    /// Summed shuttle distance over every move op (serial view, nm).
    total_move_nm: f64 = 0,

    /// Longest single move, nm.
    max_move_nm: f64 = 0,

    /// Wall-clock contributions (µs), each summed over frames.
    loading_us: f64 = 0, // pick-ups + drops
    shuttling_us: f64 = 0, // per-frame max move / speed
    entangling_us: f64 = 0, // Rydberg pulses
    raman_us_total: f64 = 0, // single-qubit pulses

    /// Wall-clock time the compiler spent producing this schedule. Filled by
    /// the driver; null when not measured.
    compile_ns: ?u64 = null,

    /// Routing quality, filled by the driver from compiler.RouteStats; null
    /// when not measured. cz_requested is the CZ gates handed to routing
    /// (cz_pairs falling short of it means the router dropped gates); colors
    /// is the timestep count summed over stages; max_degree sums each stage
    /// graph's max degree, the edge-coloring lower bound.
    cz_requested: ?usize = null,
    colors: ?usize = null,
    max_degree: ?usize = null,

    /// Routing overhead = loading + shuttling. NALAC's headline cost.
    pub fn routingUs(m: Metrics) f64 {
        return m.loading_us + m.shuttling_us;
    }

    /// Time spent firing gate pulses (entangling + single-qubit).
    pub fn gateUs(m: Metrics) f64 {
        return m.entangling_us + m.raman_us_total;
    }

    /// End-to-end schedule runtime.
    pub fn totalUs(m: Metrics) f64 {
        return m.routingUs() + m.gateUs();
    }

    /// Average CZ gates per entangling pulse — the parallelism NALAC reports.
    /// A naive serialized router scores 1.0; coloring/round-packing scores more.
    pub fn avgCzPerPulse(m: Metrics) f64 {
        if (m.n_rydberg == 0) return 0;
        return @as(f64, @floatFromInt(m.cz_pairs)) / @as(f64, @floatFromInt(m.n_rydberg));
    }
};

fn moveDistNm(m: anytype) f64 {
    const dx: f64 = @floatFromInt(m.dest.x - m.src.x);
    const dy: f64 = @floatFromInt(m.dest.y - m.src.y);
    return @sqrt(dx * dx + dy * dy);
}

/// Compute metrics for a compiled schedule under `Timing`.
pub fn measure(hw: *const schedule.Hardware) Metrics {
    return measureFrames(hw.frames.items, hw.placement.len);
}

/// Core of `measure`, taking the frame list directly so it is unit-testable
/// without constructing a full Hardware.
pub fn measureFrames(frames: []const schedule.Frame, num_qubits: usize) Metrics {
    var m = Metrics{
        .num_qubits = num_qubits,
        .frames = frames.len,
    };

    for (frames) |frame| {
        var has_load = false;
        var has_store = false;
        var has_rydberg = false;
        var has_raman = false;
        var frame_max_nm: f64 = 0;

        for (frame.items) |op| switch (op) {
            .load => {
                m.n_load += 1;
                has_load = true;
            },
            .store => {
                m.n_store += 1;
                has_store = true;
            },
            .move => |mv| {
                m.n_move += 1;
                const d = moveDistNm(mv);
                m.total_move_nm += d;
                if (d > frame_max_nm) frame_max_nm = d;
                if (d > m.max_move_nm) m.max_move_nm = d;
            },
            .rydberg => |r| {
                m.n_rydberg += 1;
                m.cz_pairs += r.pairs.len;
                has_rydberg = true;
            },
            .raman => {
                m.n_raman += 1;
                has_raman = true;
            },
            .measure => m.n_measure += 1,
        };

        // A frame is, at most: pick up (parallel), translate (rigidly, so the
        // slowest atom sets the time), drop, then pulse. Each phase costs once
        // per frame, never once per atom.
        m.shuttling_us += frame_max_nm / Timing.shuttle_nm_per_us;

        if (has_load) m.loading_us += Timing.load_us;
        if (has_store) m.loading_us += Timing.store_us;
        if (has_rydberg) m.entangling_us += Timing.rydberg_us;
        if (has_raman) m.raman_us_total += Timing.raman_us;
    }

    return m;
}

// --- Benchmark table -------------------------------------------------------

/// Fixed-width console table for suite runs (several circuits given):
///
///     circuit                   qubits  frames       cz  colors  cz/pulse ...
///     ------------------------------------------------------------------ ...
///     ex/graph/graph-10-9.qasm      10      49    21/21    10/8      2.33 ...
///
/// cz = pairs entangled in the schedule / CZ gates handed to routing: a
/// shortfall means the router dropped gates (non-bipartite MIS leftovers).
/// colors = timesteps used / max stage degree (the edge-coloring lower
/// bound), both summed over stages: the gap is the coloring's slack.
pub const Table = struct {
    /// Width of the leading `circuit` column, computed once in `init`.
    name_w: usize,

    const Col = struct { header: []const u8, w: usize };

    /// Every column after `circuit`, in print order. `row` and `totals` fill
    /// cells in this order; the header row and rule length derive from it.
    const cols = [_]Col{
        .{ .header = "qubits", .w = 6 },
        .{ .header = "frames", .w = 6 },
        .{ .header = "cz", .w = 11 },
        .{ .header = "colors", .w = 8 },
        .{ .header = "cz/pulse", .w = 8 },
        .{ .header = "shuttle_us", .w = 10 },
        .{ .header = "loading_us", .w = 10 },
        .{ .header = "total_us", .w = 8 },
        .{ .header = "compile_ms", .w = 10 },
    };

    /// Combined width of every column after `circuit`, including separators.
    const cols_width = blk: {
        var n: usize = 0;
        for (cols) |c| n += sep.len + c.w;
        break :blk n;
    };

    const sep = "  ";

    /// Running sums for the totals row; `add` once per circuit.
    pub const Totals = struct {
        circuits: usize = 0,
        cz_pairs: usize = 0,
        cz_requested: usize = 0,
        colors: usize = 0,
        max_degree: usize = 0,
        shuttling_us: f64 = 0,
        loading_us: f64 = 0,
        total_us: f64 = 0,
        compile_ns: u64 = 0,

        pub fn add(t: *Totals, m: Metrics) void {
            t.circuits += 1;
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

    /// `max_name_len`: the longest circuit path the table will show.
    pub fn init(max_name_len: usize) Table {
        return .{ .name_w = @max(max_name_len, "circuit".len) };
    }

    pub fn header(t: Table) void {
        var cells: [cols.len][]const u8 = undefined;
        for (cols, &cells) |c, *s| s.* = c.header;
        t.printRow("circuit", cells);
        t.rule();
    }

    pub fn row(t: Table, name: []const u8, m: Metrics) void {
        var bufs: [cols.len][32]u8 = undefined;
        t.printRow(name, .{
            fmtCell(&bufs[0], "{d}", .{m.num_qubits}),
            fmtCell(&bufs[1], "{d}", .{m.frames}),
            fmtCell(&bufs[2], "{d}/{d}", .{ m.cz_pairs, m.cz_requested orelse 0 }),
            fmtCell(&bufs[3], "{d}/{d}", .{ m.colors orelse 0, m.max_degree orelse 0 }),
            fmtCell(&bufs[4], "{d:.2}", .{m.avgCzPerPulse()}),
            fmtCell(&bufs[5], "{d:.1}", .{m.shuttling_us}),
            fmtCell(&bufs[6], "{d:.1}", .{m.loading_us}),
            fmtCell(&bufs[7], "{d:.1}", .{m.totalUs()}),
            fmtCell(&bufs[8], "{d:.2}", .{compileMs(m.compile_ns orelse 0)}),
        });
    }

    pub fn totals(t: Table, sum: Totals) void {
        t.rule();
        var bufs: [cols.len][32]u8 = undefined;
        var name_buf: [32]u8 = undefined;
        t.printRow(fmtCell(&name_buf, "{d} circuits", .{sum.circuits}), .{
            "",
            "",
            fmtCell(&bufs[2], "{d}/{d}", .{ sum.cz_pairs, sum.cz_requested }),
            fmtCell(&bufs[3], "{d}/{d}", .{ sum.colors, sum.max_degree }),
            "",
            fmtCell(&bufs[5], "{d:.1}", .{sum.shuttling_us}),
            fmtCell(&bufs[6], "{d:.1}", .{sum.loading_us}),
            fmtCell(&bufs[7], "{d:.1}", .{sum.total_us}),
            fmtCell(&bufs[8], "{d:.2}", .{compileMs(sum.compile_ns)}),
        });
    }

    fn rule(t: Table) void {
        for (0..t.name_w + cols_width) |_| std.debug.print("-", .{});
        std.debug.print("\n", .{});
    }

    /// `name` left-aligned to the circuit column, each cell right-aligned to
    /// its spec width. An overlong cell widens its column rather than being
    /// truncated.
    fn printRow(t: Table, name: []const u8, cells: [cols.len][]const u8) void {
        std.debug.print("{[name]s:<[w]}", .{ .name = name, .w = t.name_w });
        for (cols, cells) |c, s|
            std.debug.print(sep ++ "{[cell]s:>[w]}", .{ .cell = s, .w = c.w });
        std.debug.print("\n", .{});
    }

    fn fmtCell(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(buf, fmt, args) catch "?";
    }

    fn compileMs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    }
};

test "measureFrames sums routing overhead and parallelism per frame" {
    const gpa = std.testing.allocator;

    // Frame 0: pick two atoms up (one parallel load phase).
    var f0: schedule.Frame = .empty;
    defer f0.deinit(gpa);

    try f0.append(gpa, .{
        .load = .{
            .qubit = 0,
            .position = .{ .x = 0, .y = 0 },
        },
    });

    try f0.append(gpa, .{
        .load = .{
            .qubit = 1,
            .position = .{ .x = 1100, .y = 0 },
        },
    });

    // Frame 1: translate (1100 nm and 550 nm in parallel -> 1100 sets the
    // time) then drop.
    var f1: schedule.Frame = .empty;
    defer f1.deinit(gpa);

    try f1.append(gpa, .{
        .move = .{
            .qubit = 0,
            .src = .{ .x = 0, .y = 0 },
            .dest = .{ .x = 1100, .y = 0 },
        },
    });

    try f1.append(gpa, .{
        .move = .{
            .qubit = 1,
            .src = .{ .x = 1100, .y = 0 },
            .dest = .{ .x = 1650, .y = 0 },
        },
    });

    try f1.append(gpa, .{
        .store = .{
            .qubit = 0,
            .position = .{ .x = 1100, .y = 0 },
        },
    });

    try f1.append(gpa, .{
        .store = .{
            .qubit = 1,
            .position = .{ .x = 1650, .y = 0 },
        },
    });

    // Frame 2: one pulse entangling two pairs.
    var f2: schedule.Frame = .empty;
    defer f2.deinit(gpa);

    try f2.append(gpa, .{
        .rydberg = .{
            .zone = .compute,
            .pairs = &.{
                .{ 0, 1 },
                .{ 2, 3 },
            },
        },
    });

    const frames = [_]schedule.Frame{ f0, f1, f2 };
    const m = measureFrames(&frames, 4);

    try std.testing.expectEqual(@as(usize, 3), m.frames);
    try std.testing.expectEqual(@as(usize, 2), m.n_load);
    try std.testing.expectEqual(@as(usize, 2), m.n_store);
    try std.testing.expectEqual(@as(usize, 2), m.n_move);
    try std.testing.expectEqual(@as(usize, 1), m.n_rydberg);
    try std.testing.expectEqual(@as(usize, 2), m.cz_pairs);

    try std.testing.expectApproxEqAbs(@as(f64, 1650.0), m.total_move_nm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1100.0), m.max_move_nm, 1e-9);

    // loading: one load phase (20) + one store phase (20) = 40.
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), m.loading_us, 1e-9);
    // shuttling: frame 1's max move 1100 nm / 550 nm/µs = 2.0 µs.
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), m.shuttling_us, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), m.entangling_us, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), m.routingUs(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 42.2), m.totalUs(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), m.avgCzPerPulse(), 1e-9);
}

test {
    std.testing.refAllDecls(@This());
}
