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
const trace = @import("trace");

/// Route one stage's CZ gates: build the interaction graph and compile it
/// into a logical Sequence. Caller owns the result.
pub fn routeStage(gpa: std.mem.Allocator, cz_gates: []const circuit.Cz, num_qubits: usize) !route.Sequence {
    var g = try route.Graph.init(gpa, num_qubits, false);
    defer g.deinit();

    for (cz_gates) |gate| try g.addEdge(gate.control, gate.target);

    return route.computeSequence(gpa, &g);
}

/// Route one stage's CZ gates into one or more pickup rounds, appended to
/// `out`. A coloring whose per-class left-right constraints conflict cannot
/// ride a single rigid AOD register; CZ gates commute, so such a set is
/// split in half and each half routed as its own round (each round gets a
/// fresh register, so the conflicting classes never share a column order).
pub fn routeStageRounds(
    gpa: std.mem.Allocator,
    cz_gates: []const circuit.Cz,
    num_qubits: usize,
    out: *std.ArrayList(route.Sequence),
) !void {
    const sequence = routeStage(gpa, cz_gates, num_qubits) catch |err| switch (err) {
        error.CyclicAodOrder, error.CyclicSlmConstraints => {
            if (cz_gates.len < 2) return err;
            const mid = cz_gates.len / 2;
            try routeStageRounds(gpa, cz_gates[0..mid], num_qubits, out);
            try routeStageRounds(gpa, cz_gates[mid..], num_qubits, out);
            return;
        },
        else => return err,
    };
    errdefer {
        var s = sequence;
        s.deinit();
    }
    try out.append(gpa, sequence);
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
) !schedule.Hardware {
    var hw = try schedule.Hardware.init(gpa, cfg, pipe.num_qubits, initial_sites);
    errdefer hw.deinit();

    // Per-qubit virtual-Z frame phase, accumulated across stages by lowerU.
    // Bookkeeping per qubit across all timesteps. We are not rotating the
    // qubit, we are rotating the coordinate system we'll describe all future pulses in.
    const frame_phase = try gpa.alloc(f64, pipe.num_qubits);
    @memset(frame_phase, 0);
    defer gpa.free(frame_phase);

    for (pipe.stages.items) |*stage| {
        // A stage with no CZ gates has nothing to route, so it is pure Raman pulses.
        if (stage.cz_gates.items.len > 0) {
            var rounds: std.ArrayList(route.Sequence) = .empty;
            defer {
                for (rounds.items) |*s| s.deinit();
                rounds.deinit(gpa);
            }
            try routeStageRounds(gpa, stage.cz_gates.items, pipe.num_qubits, &rounds);

            for (rounds.items) |*sequence| {
                if (trace.enabled) sequence.print();

                try hw.moveSlmCompute(sequence.fixed);
                try hw.moveAodCompute(sequence.fixed, sequence.moveable);
                try hw.moveAodStorage(sequence.moveable);
                try hw.moveSlmStorage(sequence.fixed);
            }
        }

        // U gates fire last: within a stage, CZs precede the U barrier,
        // and by now all atoms are back at their storage positions.
        const pulses = try gpa.alloc(schedule.RamanGate, stage.u_gates.items.len);
        defer gpa.free(pulses);

        var n: usize = 0;
        for (stage.u_gates.items) |gate| {
            if (lowerU(&frame_phase[gate.qubit], gate)) |p| {
                pulses[n] = p;
                n += 1;
            }
        }
        try hw.raman(pulses[0..n]);
    }

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

test {
    std.testing.refAllDecls(@This());
}
