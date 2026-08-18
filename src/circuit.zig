//! Front-end IR: the `Circuit` gate list built by the QASM parser.
//! Decompose stages it into a Pipeline.
//! Back-end passes (route, schedule) are orchestrated
//! over the resulting pipeline by the driver in compiler.zig.

const std = @import("std");

const PI = std.math.pi;

pub const U = struct {
    qubit: u32,
    theta: f64,
    phi: f64,
    lambda: f64,
};

pub const Cz = struct {
    control: u32,
    target: u32,
};

pub const Reset = struct {
    qubit: u32,
};

pub const Native = union(enum) {
    u: U,
    cz: Cz,
    reset: Reset,
};

pub const Stage = struct {
    u_gates: std.ArrayList(U) = .empty,
    cz_gates: std.ArrayList(Cz) = .empty,

    fn deinit(s: *Stage, gpa: std.mem.Allocator) void {
        s.u_gates.deinit(gpa);
        s.cz_gates.deinit(gpa);
    }
};

pub const Pipeline = struct {
    gpa: std.mem.Allocator,
    stages: std.ArrayList(Stage),
    num_qubits: usize,

    fn init(gpa: std.mem.Allocator, n: usize) Pipeline {
        return .{
            .gpa = gpa,
            .stages = .empty,
            .num_qubits = n,
        };
    }

    pub fn deinit(s: *Pipeline) void {
        for (s.stages.items) |*stage| stage.deinit(s.gpa);
        s.stages.deinit(s.gpa);
    }

    // Place a `gate` into stage `n`, creating intervening stages as needed.
    fn place(s: *Pipeline, n: usize, gate: Native) !void {
        while (s.stages.items.len <= n) {
            try s.stages.append(s.gpa, .{});
        }
        const stage = &s.stages.items[n];
        switch (gate) {
            .u => |g| try stage.u_gates.append(s.gpa, g),
            .cz => |g| try stage.cz_gates.append(s.gpa, g),
            // Resets are never staged (decompose skips them), so one never
            // reaches `place`.
            .reset => unreachable,
        }
    }
};

/// Group the circuit's gates into stages. Stages are homogeneous - all CZ
/// or all U - so the pipeline alternates choreographed CZ episodes with
/// Raman-pulse episodes, and an idle qubit's U joins the nearest U stage
/// rather than riding along in a CZ stage.
///
/// Gates never reorder across a shared qubit; across disjoint qubits
/// a gate may join an earlier stage of its kind, which is safe
/// exactly because disjoint gates commute.
pub fn decompose(gpa: std.mem.Allocator, c: Circuit) !Pipeline {
    var pipe = Pipeline.init(gpa, c.n);
    errdefer pipe.deinit();

    // Earliest stage of the wanted kind at or past `from`. A stage's kind
    // is whichever list is populated; falling off the end names the fresh stage that
    // place() then creates.
    const fit = struct {
        fn earliest(stages: []const Stage, from: usize, cz: bool) usize {
            var s = from;
            while (s < stages.len and (stages[s].cz_gates.items.len != 0) != cz) s += 1;
            return s;
        }
    }.earliest;

    // Per-qubit cursor: the stage holding the qubit's latest gate.
    const cursors = try gpa.alloc(usize, c.n);
    defer gpa.free(cursors);
    @memset(cursors, 0);

    for (c.gates.items) |gate| {
        const q: [2]u32 = switch (gate) {
            .u => |g| .{ g.qubit, g.qubit },
            .cz => |g| .{ g.control, g.target },
            // TODO: implement proper reseting.
            .reset => continue,
        };
        const from = @max(cursors[q[0]], cursors[q[1]]);
        const stage = fit(pipe.stages.items, from, gate == .cz);
        try pipe.place(stage, gate);
        // Pin every touched qubit to the gate's stage, or a later gate on
        // a qubit that was lagging would be staged before this one.
        cursors[q[0]] = stage;
        cursors[q[1]] = stage;
    }

    return pipe;
}

pub const Circuit = struct {
    gpa: std.mem.Allocator,
    gates: std.ArrayList(Native),
    n: usize,

    pub fn init(gpa: std.mem.Allocator, n_qubits: usize) Circuit {
        const gates: std.ArrayList(Native) = .empty;
        return .{
            .gpa = gpa,
            .gates = gates,
            .n = n_qubits,
        };
    }

    pub fn deinit(s: *Circuit) void {
        s.gates.deinit(s.gpa);
    }

    pub fn h(s: *Circuit, q: u32) !void {
        try s.u(q, PI / 2.0, 0.0, PI);
    }

    pub fn x(s: *Circuit, q: u32) !void {
        try s.u(q, PI, 0.0, PI);
    }

    pub fn y(s: *Circuit, q: u32) !void {
        try s.u(q, PI, PI / 2.0, PI / 2.0);
    }

    pub fn z(s: *Circuit, q: u32) !void {
        try s.u(q, 0.0, 0.0, PI);
    }

    pub fn rx(s: *Circuit, q: u32, theta: f64) !void {
        try s.u(q, theta, -PI / 2.0, PI / 2.0);
    }

    pub fn ry(s: *Circuit, q: u32, theta: f64) !void {
        try s.u(q, theta, 0.0, 0.0);
    }

    pub fn rz(s: *Circuit, q: u32, angle: f64) !void {
        try s.u(q, 0.0, 0.0, angle);
    }

    pub fn u(s: *Circuit, q: u32, theta: f64, phi: f64, lambda: f64) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = phi,
            .lambda = lambda,
        } });
    }

    pub fn cz(s: *Circuit, control: u32, target: u32) !void {
        try s.gates.append(s.gpa, .{ .cz = .{
            .control = control,
            .target = target,
        } });
    }

    pub fn cx(s: *Circuit, control: u32, target: u32) !void {
        try s.h(target);
        try s.cz(control, target);
        try s.h(target);
    }

    pub fn reset(s: *Circuit, q: u32) !void {
        try s.gates.append(s.gpa, .{ .reset = .{ .qubit = q } });
    }

    // Rzz(theta) = exp(-i*theta/2 * Z⊗Z), the two-qubit ZZ rotation, via the
    // textbook CX–Rz–CX decomposition (up to global phase, like the rest).
    pub fn rzz(s: *Circuit, a: u32, b: u32, theta: f64) !void {
        try s.cx(a, b);
        try s.rz(b, theta);
        try s.cx(a, b);
    }

    pub fn sx(s: *Circuit, q: u32) !void {
        try s.u(q, PI / 2.0, -PI / 2.0, PI / 2.0);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "decompose merges a run of commuting CZs into one stage" {
    var c = Circuit.init(std.testing.allocator, 3);
    defer c.deinit();
    try c.cz(0, 1);
    try c.cz(1, 2); // shares q1 with the first CZ, but CZs commute

    var pipe = try decompose(std.testing.allocator, c);
    defer pipe.deinit();

    try std.testing.expectEqual(1, pipe.stages.items.len);
    try std.testing.expectEqual(2, pipe.stages.items[0].cz_gates.items.len);
}

test "decompose: a U barrier splits CZs on its qubit into separate stages" {
    var c = Circuit.init(std.testing.allocator, 2);
    defer c.deinit();
    try c.cz(0, 1);
    try c.h(1);
    try c.cz(0, 1);

    var pipe = try decompose(std.testing.allocator, c);
    defer pipe.deinit();

    // The barrier H gets its own stage between the CZs: a U and a CZ on
    // the same qubit never share a stage.
    try std.testing.expectEqual(3, pipe.stages.items.len);
    try std.testing.expectEqual(1, pipe.stages.items[0].cz_gates.items.len);
    try std.testing.expectEqual(1, pipe.stages.items[1].u_gates.items.len);
    try std.testing.expectEqual(1, pipe.stages.items[2].cz_gates.items.len);
}

test "decompose never stages a gate before a preceding gate on its qubit" {
    // h(1); cz(0,1); h(0) — q0 lags q1 at the CZ. The trailing h(0) must
    // land after the CZ's stage, never before or beside it.
    var c = Circuit.init(std.testing.allocator, 2);
    defer c.deinit();
    try c.h(1);
    try c.cz(0, 1);
    try c.h(0);

    var pipe = try decompose(std.testing.allocator, c);
    defer pipe.deinit();

    try std.testing.expectEqual(3, pipe.stages.items.len);

    const s0 = pipe.stages.items[0];
    try std.testing.expectEqual(0, s0.cz_gates.items.len);
    try std.testing.expectEqual(1, s0.u_gates.items.len);
    try std.testing.expectEqual(1, s0.u_gates.items[0].qubit);

    const s1 = pipe.stages.items[1];
    try std.testing.expectEqual(1, s1.cz_gates.items.len);
    try std.testing.expectEqual(0, s1.u_gates.items.len);

    const s2 = pipe.stages.items[2];
    try std.testing.expectEqual(1, s2.u_gates.items.len);
    try std.testing.expectEqual(0, s2.u_gates.items[0].qubit);
}

test "decompose keeps stages homogeneous: an idle-qubit U joins the U stage" {
    // q2 is untouched by the CZ, so its U *could* run beside it — but a
    // stage is one episode kind, so the U belongs in the U stage with the
    // post-CZ U on q0.
    var c = Circuit.init(std.testing.allocator, 3);
    defer c.deinit();
    try c.cz(0, 1);
    try c.h(2);
    try c.h(0);

    var pipe = try decompose(std.testing.allocator, c);
    defer pipe.deinit();

    try std.testing.expectEqual(2, pipe.stages.items.len);
    try std.testing.expectEqual(1, pipe.stages.items[0].cz_gates.items.len);
    try std.testing.expectEqual(0, pipe.stages.items[0].u_gates.items.len);
    try std.testing.expectEqual(0, pipe.stages.items[1].cz_gates.items.len);
    try std.testing.expectEqual(2, pipe.stages.items[1].u_gates.items.len);
}

test "decompose stacks same-qubit U runs into single stages" {
    // The bell pattern: a run of U's per qubit, one CZ, a trailing U run.
    // U's on one qubit fire as sequential pulses within a stage, so only
    // the CZ/U boundaries split: three stages, not one per U layer.
    var c = Circuit.init(std.testing.allocator, 2);
    defer c.deinit();
    try c.h(0);
    try c.x(0);
    try c.h(1);
    try c.x(1);
    try c.cz(0, 1);
    try c.h(1);
    try c.x(1);

    var pipe = try decompose(std.testing.allocator, c);
    defer pipe.deinit();

    try std.testing.expectEqual(3, pipe.stages.items.len);
    try std.testing.expectEqual(4, pipe.stages.items[0].u_gates.items.len);
    try std.testing.expectEqual(1, pipe.stages.items[1].cz_gates.items.len);
    try std.testing.expectEqual(0, pipe.stages.items[1].u_gates.items.len);
    try std.testing.expectEqual(2, pipe.stages.items[2].u_gates.items.len);
}

test {
    std.testing.refAllDecls(@This());
}
