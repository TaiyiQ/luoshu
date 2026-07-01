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

/// Physical timing constants. Defaults are NALAC's (arXiv:2405.08068, §V):
/// shuttle 0.55 µm/µs, load/store 20 µs each, CZ pulse 0.2 µs. Override to
/// model a different platform.
pub const Timing = struct {
    /// AOD transport speed, nm per µs (NALAC: 0.55 µm/µs = 550 nm/µs).
    shuttle_nm_per_us: f64 = 550.0,

    /// AOD pick-up time (trap ramp-on), µs.
    load_us: f64 = 20.0,

    /// SLM drop time (trap hand-off), µs.
    store_us: f64 = 20.0,

    /// Rydberg/CZ entangling pulse, µs.
    rydberg_us: f64 = 0.2,

    /// Single-qubit Raman pulse, µs. NALAC does not model 1Q gate time; the
    /// default of 0 keeps the reported total comparable to the paper. Set it to
    /// fold single-qubit time into the runtime.
    raman_us: f64 = 0.0,
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

    timing: Timing,

    /// Wall-clock time the compiler spent producing this schedule. Filled by
    /// the driver; null when not measured.
    compile_ns: ?u64 = null,

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

/// Compute metrics for a compiled schedule under `timing`.
pub fn measure(hw: *const schedule.Hardware, timing: Timing) Metrics {
    return measureFrames(hw.frames.items, hw.placement.len, timing);
}

/// Core of `measure`, taking the frame list directly so it is unit-testable
/// without constructing a full Hardware.
pub fn measureFrames(frames: []const schedule.Frame, num_qubits: usize, timing: Timing) Metrics {
    var m = Metrics{
        .num_qubits = num_qubits,
        .frames = frames.len,
        .timing = timing,
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
        m.shuttling_us += frame_max_nm / timing.shuttle_nm_per_us;

        if (has_load) m.loading_us += timing.load_us;
        if (has_store) m.loading_us += timing.store_us;
        if (has_rydberg) m.entangling_us += timing.rydberg_us;
        if (has_raman) m.raman_us_total += timing.raman_us;
    }

    return m;
}

test "measureFrames sums routing overhead and parallelism per frame" {
    const gpa = std.testing.allocator;

    // Frame 0: pick two atoms up (one parallel load phase).
    var f0: schedule.Frame = .empty;
    defer f0.deinit(gpa);
    try f0.append(gpa, .{ .load = .{ .qubit = 0, .position = .{ .x = 0, .y = 0 } } });
    try f0.append(gpa, .{ .load = .{ .qubit = 1, .position = .{ .x = 1100, .y = 0 } } });

    // Frame 1: translate (1100 nm and 550 nm in parallel -> 1100 sets the
    // time) then drop.
    var f1: schedule.Frame = .empty;
    defer f1.deinit(gpa);
    try f1.append(gpa, .{ .move = .{ .qubit = 0, .src = .{ .x = 0, .y = 0 }, .dest = .{ .x = 1100, .y = 0 } } });
    try f1.append(gpa, .{ .move = .{ .qubit = 1, .src = .{ .x = 1100, .y = 0 }, .dest = .{ .x = 1650, .y = 0 } } });
    try f1.append(gpa, .{ .store = .{ .qubit = 0, .position = .{ .x = 1100, .y = 0 } } });
    try f1.append(gpa, .{ .store = .{ .qubit = 1, .position = .{ .x = 1650, .y = 0 } } });

    // Frame 2: one pulse entangling two pairs.
    var f2: schedule.Frame = .empty;
    defer f2.deinit(gpa);
    try f2.append(gpa, .{ .rydberg = .{ .zone = .compute, .pairs = &.{ .{ 0, 1 }, .{ 2, 3 } } } });

    const frames = [_]schedule.Frame{ f0, f1, f2 };
    const m = measureFrames(&frames, 4, .{});

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
