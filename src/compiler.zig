//! Pass driver: runs the back-end over the front-end's stages.
//!
//! For each stage: route (CZ interaction graph -> logical Sequence), then
//! schedule (choreograph the sequence onto Hardware frames). This is the
//! only file that sees the whole pipeline; circuit, route, and schedule
//! do not import each other:
//!
//!     arch <- schedule <- compiler -> route -> circuit

const std = @import("std");
const arch = @import("arch");
const circuit = @import("circuit");
const route = @import("route");
const schedule = @import("schedule");

const Graph = @import("graph").Graph;

/// Routing quality counters, accumulated over every routing round of a
/// compile. `cz_requested` counts the CZ gates handed to routing; the
/// schedule's entangled pairs (bench.Metrics.cz_pairs) fall short of it
/// only when a gate list repeats a pair within one stage (the interaction
/// graph deduplicates). `colors` sums each round's timestep count and
/// `max_degree` each round graph's max degree - the edge-coloring lower
/// bound - so their gap is the slack the constrained coloring left on the
/// table.
pub const RouteStats = struct {
    cz_requested: usize = 0,
    colors: usize = 0,
    max_degree: usize = 0,
};

/// Route one stage's CZ gates to completion. Each round flies a maximal
/// independent set and gates every edge it covers; edges between two
/// grounded qubits cannot gate that round and survive into the next
/// round's interaction graph, so no CZ is ever dropped (non-bipartite
/// graphs always leave such a residue). Returns one Sequence per round;
/// the caller owns the slice and every element.
pub fn routeStage(
    gpa: std.mem.Allocator,
    cz_gates: []const circuit.Cz,
    num_qubits: usize,
    stats: ?*RouteStats,
) ![]route.Sequence {
    var sequences: std.ArrayList(route.Sequence) = .empty;
    errdefer {
        for (sequences.items) |*s| s.deinit();
        sequences.deinit(gpa);
    }

    if (stats) |s| s.cz_requested += cz_gates.len;

    var remaining: std.ArrayList(circuit.Cz) = .empty;
    defer remaining.deinit(gpa);
    try remaining.appendSlice(gpa, cz_gates);

    while (remaining.items.len > 0) {
        var g = try Graph.init(gpa, num_qubits, false);
        defer g.deinit();

        for (remaining.items) |gate| try g.addEdge(gate.control, gate.target);

        // Capacity first, so the fresh Sequence lands in
        // the list with no fallible step in between.
        try sequences.ensureUnusedCapacity(gpa, 1);
        sequences.appendAssumeCapacity(try route.computeSequence(gpa, &g));

        if (stats) |s| {
            const max_c = try g.maxColor();
            s.colors += @intCast(max_c + 1);

            var delta: usize = 0;
            for (g.degree) |d| delta = @max(delta, d);
            s.max_degree += delta;
        }

        // Rebuild the gate list in place with the residue:
        // edges this round never colored.
        remaining.clearRetainingCapacity();
        for (0..g.n) |x| {
            var e = g.edges[x];
            while (e) |edge| : (e = edge.next) {
                if (x < edge.y and edge.color == null) {
                    try remaining.append(gpa, .{ .control = @intCast(x), .target = @intCast(edge.y) });
                }
            }
        }

        // Every round gates at least one AOD's full
        // edge set, so the residue must shrink.
        if (remaining.items.len == g.m) return error.NoRoutingProgress;
    }

    return sequences.toOwnedSlice(gpa);
}

/// Wrap an angle onto the canonical branch (-pi, pi].
///
/// Lossless for pulses: R(theta,beta) is exactly 2pi-periodic in beta, because
/// the -1 factors from Rz's 4pi periodicity cancel between Rz(beta) and
/// Rz(-beta). Dropping 2pi multiples of the frame phase only changes
/// Rz(frame_phase) by a global sign, which is unphysical.
fn wrapPhase(x: f64) f64 {
    return std.math.pi - @mod(std.math.pi - x, 2 * std.math.pi);
}

/// Lower one circuit.U gate to at most one schedule.RamanGate pulse.
///
/// A pulse R(theta,beta) = Rz(beta)*Ry(theta)*Rz(-beta) only rotates about
/// axes in the XY plane, so the Rz factors of U(theta,phi,lambda) = Rz(phi)*Ry(theta)*Rz(lambda)
/// are never fired. They accumulate per qubit in `frame_phase`, and setting
/// phase = -(lambda + frame_phase) makes the single pulse act like the whole U.
fn lowerU(frame_phase: *f64, gate: circuit.U) ?schedule.RamanGate {
    // A pure z-rotation (theta = 0) goes entirely into the frame phase and emits no pulse.
    const pulse: ?schedule.RamanGate = if (gate.theta == 0) null else .{
        .qubit = gate.qubit,
        .angle = gate.theta,
        .phase = wrapPhase(-(gate.lambda + frame_phase.*)),
    };

    // Phase reference tracking.
    frame_phase.* = wrapPhase(frame_phase.* + gate.phi + gate.lambda);

    return pulse;
}

/// Compile a staged circuit into a hardware schedule. `initial_sites` is the
/// storage occupancy delivered by the upstream atom-rearrangement package
/// (null falls back to the procedural placement in Hardware.init).
pub fn compile(
    gpa: std.mem.Allocator,
    pipe: *const circuit.Pipeline,
    cfg: arch.ArchConfig,
    initial_sites: ?[]const schedule.Site,
    stats: ?*RouteStats,
) !schedule.Hardware {
    var hw = try schedule.Hardware.init(gpa, cfg, pipe.num_qubits, initial_sites);
    errdefer hw.deinit();

    // Per-qubit virtual-Z frame phase, accumulated across stages by lowerU.
    // Bookkeeping per qubit across all timesteps. We are not rotating the
    // qubit, we are rotating the coordinate system we'll describe all future pulses in.
    const frame_phase = try gpa.alloc(f64, pipe.num_qubits);
    @memset(frame_phase, 0);
    defer gpa.free(frame_phase);

    // Per-qubit count of pulses already assigned in the current stage;
    // a pulse's count is its raman wave. Reset at each stage.
    const rank = try gpa.alloc(usize, pipe.num_qubits);
    defer gpa.free(rank);

    // Per-qubit dedup scratch for reset stages.
    const seen = try gpa.alloc(bool, pipe.num_qubits);
    defer gpa.free(seen);

    for (pipe.stages.items) |*stage| switch (stage.*) {
        .reset => |resets| {
            var qubits: std.ArrayList(u32) = .empty;
            defer qubits.deinit(gpa);
            @memset(seen, false);

            for (resets.items) |g| {
                if (seen[g.qubit]) continue; // reset q; reset q; is one repump
                seen[g.qubit] = true;
                frame_phase[g.qubit] = 0;
                try qubits.append(gpa, g.qubit);
            }

            try hw.moveResetReadout(qubits.items);
            try hw.reset(qubits.items);
            try hw.moveResetStorage(qubits.items);
        },

        .cz => |czs| {
            const sequences = try routeStage(
                gpa,
                czs.items,
                pipe.num_qubits,
                stats,
            );
            defer {
                for (sequences) |*s| s.deinit();
                gpa.free(sequences);
            }

            for (sequences) |*sequence| {
                sequence.print();

                try hw.moveSlmCompute(sequence.fixed);
                try hw.moveAodCompute(sequence.fixed, sequence.moveable);
                try hw.moveAodStorage(sequence.moveable);
                try hw.moveSlmStorage(sequence.fixed);
            }
        },

        .u => |us| {
            const Pulse = struct {
                wave: usize,
                gate: schedule.RamanGate,
            };

            const pulses = try gpa.alloc(Pulse, us.items.len);
            defer gpa.free(pulses);

            @memset(rank, 0);

            var n: usize = 0;
            for (us.items) |gate| {
                const p = lowerU(&frame_phase[gate.qubit], gate) orelse continue;

                pulses[n] = .{
                    .wave = rank[gate.qubit],
                    .gate = p,
                };

                n += 1;

                rank[gate.qubit] += 1;
            }

            // Waves group contiguously, gate order within a wave holds.
            std.mem.sort(Pulse, pulses[0..n], {}, struct {
                fn lt(_: void, a: Pulse, b: Pulse) bool {
                    return a.wave < b.wave;
                }
            }.lt);

            const batch = try gpa.alloc(schedule.RamanGate, n);
            defer gpa.free(batch);

            for (pulses[0..n], batch) |p, *b| b.* = p.gate;

            var start: usize = 0;
            while (start < n) {
                var end = start + 1;
                while (end < n and pulses[end].wave == pulses[start].wave) end += 1;
                try hw.raman(batch[start..end]);
                start = end;
            }
        },
    };

    try hw.moveReadout();

    try hw.measure(.readout);

    return hw;
}

// lowerU never fires the accumulated Rz(frame_phase), so its pulses alone do
// NOT equal the U gates they came from. The real claim is
//
//     Rz(frame_phase) * (pulses, in order)  =  (U gates, in order)
//
// and this test checks it directly: multiply out both sides as 2x2 matrices
// and compare.
test "lowerU: pulse stream plus residual frame phase reproduces the U product" {
    // Just enough linear algebra to do that: a single-qubit gate is a 2x2
    // complex unitary, and applying gates in sequence is matrix multiplication.
    const m = struct {
        const C = std.math.Complex(f64);
        const Mat = [2][2]C;

        const id = Mat{
            .{ C.init(1, 0), C.init(0, 0) },
            .{ C.init(0, 0), C.init(1, 0) },
        };

        fn mul(a: Mat, b: Mat) Mat {
            var r: Mat = undefined;
            for (0..2) |i| for (0..2) |j| {
                r[i][j] = a[i][0].mul(b[0][j]).add(a[i][1].mul(b[1][j]));
            };
            return r;
        }

        // Conjugate transpose. For a unitary this is the inverse.
        fn dag(x: Mat) Mat {
            return .{
                .{ x[0][0].conjugate(), x[1][0].conjugate() },
                .{ x[0][1].conjugate(), x[1][1].conjugate() },
            };
        }

        // Use Euler's equation.
        fn rz(a: f64) Mat {
            return .{
                .{ C.init(@cos(a / 2), -@sin(a / 2)), C.init(0, 0) },
                .{ C.init(0, 0), C.init(@cos(a / 2), @sin(a / 2)) },
            };
        }

        fn ry(t: f64) Mat {
            return .{
                .{ C.init(@cos(t / 2), 0), C.init(-@sin(t / 2), 0) },
                .{ C.init(@sin(t / 2), 0), C.init(@cos(t / 2), 0) },
            };
        }

        // What a U gate means: U(theta,phi,lambda) = Rz(phi)*Ry(theta)*Rz(lambda).
        fn uMat(g: circuit.U) Mat {
            return mul(rz(g.phi), mul(ry(g.theta), rz(g.lambda)));
        }

        // What one pulse does: R(theta,beta) = Rz(beta)*Ry(theta)*Rz(-beta),
        // a rotation by angle theta about the XY-plane axis picked by beta.
        // Written from the definition, independent of lowerU, so it can
        // catch lowerU's bugs.
        fn pulseMat(p: schedule.RamanGate) Mat {
            return mul(rz(p.phase), mul(ry(p.angle), rz(-p.phase)));
        }
    };

    // One of each U shape the front end emits. In sequence they push
    // `frame_phase` through several nonzero values, so every pulse's phase
    // shift matters.
    const pi = std.math.pi;
    const gates = [_]circuit.U{
        .{ .qubit = 0, .theta = pi / 2.0, .phi = 0, .lambda = pi }, // h
        .{ .qubit = 0, .theta = 0, .phi = 0, .lambda = 0.7 }, // rz(0.7)
        .{ .qubit = 0, .theta = pi, .phi = 0, .lambda = pi }, // x
        .{ .qubit = 0, .theta = 1.1, .phi = -pi / 2.0, .lambda = pi / 2.0 }, // rx(1.1)
        .{ .qubit = 0, .theta = pi, .phi = pi / 2.0, .lambda = pi / 2.0 }, // y
    };

    var frame_phase: f64 = 0;
    var applied = m.id;
    var desired = m.id;
    var n_pulses: usize = 0;

    // Build both sides. Applying a gate to a state multiplies on the left,
    // so `desired` is what the U gates mean and `applied` is what the
    // emitted pulses actually do.
    for (gates) |g| {
        desired = m.mul(m.uMat(g), desired);
        if (lowerU(&frame_phase, g)) |p| {
            // Every emitted phase sits on the canonical branch (-pi, pi].
            try std.testing.expect(p.phase > -pi and p.phase <= pi);
            applied = m.mul(m.pulseMat(p), applied);
            n_pulses += 1;
        }
    }

    // The pure z-rotation - Rz(0.7) (theta = 0) - fired no pulse.
    try std.testing.expectEqual(gates.len - 1, n_pulses);

    // The two sides may differ by a global phase e^{i*alpha}, which is
    // physically meaningless but breaks entry-wise comparison. To cancel it,
    // compare by division instead of subtraction: applied and desired are
    // unitary (dag = inverse), so
    //
    //     desired = e^{i*alpha} * applied   if
    //     dag(applied) * desired = e^{i*alpha} * identity
    //
    // i.e. the quotient must be zero off the diagonal and carry the same
    // unit-magnitude number (the global phase) twice on it.
    const applied_total = m.mul(m.rz(frame_phase), applied);
    const quot = m.mul(m.dag(applied_total), desired);

    const tol = 1e-12;
    try std.testing.expectApproxEqAbs(0.0, quot[0][1].magnitude(), tol);
    try std.testing.expectApproxEqAbs(0.0, quot[1][0].magnitude(), tol);
    try std.testing.expectApproxEqAbs(1.0, quot[0][0].magnitude(), tol);
    try std.testing.expectApproxEqAbs(0.0, quot[0][0].sub(quot[1][1]).magnitude(), tol);
}

// The compiler-level completeness pin, sibling of route.zig's single-round
// coverage test: computeSequence provably cannot cover a non-bipartite
// graph in one round (the known_incomplete cases assert that), so this
// checks that routeStage's residue loop closes the gap - every edge of
// every snapshot graph gates exactly once across the rounds, and nothing
// gates that was not asked for. Gates are reconstructed from the sequences
// themselves: an AOD qubit sharing a column with an SLM qubit at some
// timestep is one fired CZ.
test "routeStage gates every stage edge exactly once across rounds" {
    const gpa = std.testing.allocator;

    for (route.snapshot_cases) |case| {
        var g = try route.buildSnapshotGraph(case.kind, gpa);
        defer g.deinit();

        // The stage's gate list: one Cz per undirected edge.
        var gates: std.ArrayList(circuit.Cz) = .empty;
        defer gates.deinit(gpa);

        for (0..g.n) |x| {
            var e = g.edges[x];
            while (e) |edge| : (e = edge.next) {
                if (x < edge.y) {
                    try gates.append(gpa, .{
                        .control = @intCast(x),
                        .target = @intCast(edge.y),
                    });
                }
            }
        }

        const sequences = try routeStage(gpa, gates.items, g.n, null);
        defer {
            for (sequences) |*s| s.deinit();
            gpa.free(sequences);
        }

        // fired[lo * n + hi] = times the pair (lo, hi) gated.
        const fired = try gpa.alloc(usize, g.n * g.n);
        defer gpa.free(fired);
        @memset(fired, 0);

        for (sequences) |seq| {
            for (seq.moveable) |row| {
                for (row, seq.fixed) |aod, slm| {
                    const q = aod orelse continue;
                    const p = slm orelse continue;
                    fired[@min(p, q) * g.n + @max(p, q)] += 1;
                }
            }
        }

        for (gates.items) |gate| {
            const lo: usize = @min(gate.control, gate.target);
            const hi: usize = @max(gate.control, gate.target);
            try std.testing.expectEqual(@as(usize, 1), fired[lo * g.n + hi]);
        }

        var total: usize = 0;
        for (fired) |n| total += n;

        try std.testing.expectEqual(gates.items.len, total);
    }
}

test {
    std.testing.refAllDecls(@This());
}
