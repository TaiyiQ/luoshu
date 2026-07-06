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

/// A non-unitary reset of a qubit to |0⟩. Recorded in the front-end circuit
/// (so the original-circuit drawing shows it) but not lowered into the
/// hardware schedule: `decompose` skips it.
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
            // Resets are never staged (decompose skips them), so one never
            // reaches `place`.
            .reset => unreachable,
        }
    }
};

/// Group the circuit's gates into stages. Within a stage, the CZ gates
/// execute first, then the U gates fire as Raman pulses — sequentially per
/// qubit, in circuit order.
///
/// Only a CZ/U boundary on a shared qubit forces a new stage: CZs are
/// diagonal and mutually commute, so a run of CZs shares one stage and may
/// share qubits freely, and a run of U's on one qubit shares one stage
/// because the pulses fire in order. A qubit therefore advances to the next
/// stage exactly when its gate kind flips, and gates never reorder across a
/// shared qubit.
pub fn decompose(gpa: std.mem.Allocator, c: Circuit) !Pipeline {
    var pipe = try Pipeline.init(gpa, c.n);
    errdefer pipe.deinit();

    // Per-qubit cursor: the stage holding the qubit's latest gate, and that
    // gate's kind. A same-kind gate joins that stage; a kind flip moves past it.
    const Cursor = struct { stage: usize = 0, last: enum { none, u, cz } = .none };
    const cursors = try gpa.alloc(Cursor, c.n);
    defer gpa.free(cursors);
    @memset(cursors, .{});

    for (c.gates.items) |gate| {
        switch (gate) {
            .u => |g| {
                const cur = &cursors[g.qubit];
                if (cur.last == .cz) cur.stage += 1;
                cur.last = .u;
                try pipe.place(cur.stage, gate);
            },
            .cz => |g| {
                const a = cursors[g.control];
                const b = cursors[g.target];
                const stage = @max(
                    a.stage + @intFromBool(a.last == .u),
                    b.stage + @intFromBool(b.last == .u),
                );
                try pipe.place(stage, gate);
                // Pin both qubits to the CZ's stage, or a later gate on the
                // qubit that was lagging would be staged before this CZ.
                cursors[g.control] = .{ .stage = stage, .last = .cz };
                cursors[g.target] = .{ .stage = stage, .last = .cz };
            },
            // Reset is a front-end-only op: it carries no unitary, so it is not
            // scheduled onto the hardware pipeline.
            .reset => {},
        }
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
