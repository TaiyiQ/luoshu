//! Front-end IR: the `Circuit` gate list (built by the QASM parser in
//! qasm.zig) and `decompose`, which stages it into a `Pipeline`. Depends on
//! nothing but std; the back-end passes (route, schedule) are orchestrated
//! over the resulting `Pipeline` by the driver in compiler.zig.

const std = @import("std");

const PI = std.math.pi;

/// Qubit ids are u32 end-to-end (front-end gates through hardware ops);
/// only counts and array indices are usize.
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

pub const Native = union(enum) {
    u: U,
    cz: Cz,
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

    fn init(gpa: std.mem.Allocator, n: usize) !Pipeline {
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
        }
    }
};

/// Group the circuit's gates into stages, where a "stage" is a set of gates
/// that can run in parallel (no shared qubits within a stage).
///
/// CZ gates are diagonal and mutually commute, so any run of CZs with no
/// intervening U on a shared qubit forms one stage and may share qubits
/// freely. A U gate is a barrier: it advances its qubit to the next stage.
/// Within a stage, CZ gate indices are listed first, then U gate indices.
///
/// Returns a `Stages` = list of stages, indexed by stage number. Each stage is
/// its a list of gate indices into `c.gates.items`. Within a stage, the CZ
/// gates are listed first, followed by the U gates:
///
///     stages.items[s]      -> gate indices that run during stage s (CZs, then Us)
///     stages.items[s][k]   -> index of the k-th gate in stage s
///
///   stage 0: [ 0, 1, ..., 2, 3, ... ]   // CZ indices first, then U indices
///   stage 1: [ 4, ..., 7, ... ]
///   stage 2: [ ... ]
///
/// A qubit's stage is advanced by each U gate on it; a CZ is placed at the
/// later of its two qubits' current stages and pins both qubits there, so
/// gates never reorder across a shared qubit.
///
/// Caller owns the result and must free it with `freeStages`.
pub fn decompose(gpa: std.mem.Allocator, c: Circuit) !Pipeline {
    var pipe = try Pipeline.init(gpa, c.n);
    errdefer pipe.deinit();

    var map = std.AutoHashMap(usize, usize).init(gpa);
    defer map.deinit();
    for (0..c.n) |q| try map.put(q, 0);

    const Pending = struct { stage: usize, gate: Native };
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(gpa);

    for (c.gates.items) |gate| {
        switch (gate) {
            .u => |g| {
                const stage = map.get(g.qubit).?;
                try pending.append(gpa, .{ .stage = stage, .gate = gate });
                try map.put(g.qubit, stage + 1);
            },
            .cz => |g| {
                const stage = @max(map.get(g.control).?, map.get(g.target).?);
                try pipe.place(stage, gate);
                // Pin both qubits to the CZ's stage, or a later U on the
                // qubit that was lagging would be staged before this CZ.
                // Same-stage is fine: within a stage CZs execute first.
                try map.put(g.control, stage);
                try map.put(g.target, stage);
            },
        }
    }

    for (pending.items) |p| try pipe.place(p.stage, p.gate);

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
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = PI / 2.0,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn x(s: *Circuit, q: u32) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = PI,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn y(s: *Circuit, q: u32) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = PI,
            .phi = PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }

    pub fn z(s: *Circuit, q: u32) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = 0.0,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn rx(s: *Circuit, q: u32, theta: f64) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = -PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }

    pub fn ry(s: *Circuit, q: u32, theta: f64) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = 0.0,
            .lambda = 0.0,
        } });
    }

    pub fn rz(s: *Circuit, q: u32, angle: f64) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = 0.0,
            .phi = 0.0,
            .lambda = angle,
        } });
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

    // Rzz(theta) = exp(-i*theta/2 * Z⊗Z), the two-qubit ZZ rotation, via the
    // textbook CX–Rz–CX decomposition (up to global phase, like the rest).
    pub fn rzz(s: *Circuit, a: u32, b: u32, theta: f64) !void {
        try s.cx(a, b);
        try s.rz(b, theta);
        try s.cx(a, b);
    }

    pub fn sx(s: *Circuit, q: u32) !void {
        try s.gates.append(s.gpa, .{ .u = .{
            .qubit = q,
            .theta = PI / 2.0,
            .phi = -PI / 2.0,
            .lambda = PI / 2.0,
        } });
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

    try std.testing.expectEqual(2, pipe.stages.items.len);
    // Stage 0 holds the first CZ and the barrier H (within a stage, CZs
    // execute before Us); the second CZ lands behind the barrier.
    try std.testing.expectEqual(1, pipe.stages.items[0].cz_gates.items.len);
    try std.testing.expectEqual(1, pipe.stages.items[0].u_gates.items.len);
    try std.testing.expectEqual(1, pipe.stages.items[1].cz_gates.items.len);
}

test "decompose never stages a gate before a preceding gate on its qubit" {
    // h(1); cz(0,1); h(0) — q0 lags q1 at the CZ. The trailing h(0) must
    // land in the CZ's stage (where Us run after CZs) or later, never
    // before it.
    var c = Circuit.init(std.testing.allocator, 2);
    defer c.deinit();
    try c.h(1);
    try c.cz(0, 1);
    try c.h(0);

    var pipe = try decompose(std.testing.allocator, c);
    defer pipe.deinit();

    try std.testing.expectEqual(2, pipe.stages.items.len);

    const s0 = pipe.stages.items[0];
    try std.testing.expectEqual(0, s0.cz_gates.items.len);
    try std.testing.expectEqual(1, s0.u_gates.items.len);
    try std.testing.expectEqual(1, s0.u_gates.items[0].qubit);

    const s1 = pipe.stages.items[1];
    try std.testing.expectEqual(1, s1.cz_gates.items.len);
    try std.testing.expectEqual(1, s1.u_gates.items.len);
    try std.testing.expectEqual(0, s1.u_gates.items[0].qubit);
}

test {
    std.testing.refAllDecls(@This());
}
