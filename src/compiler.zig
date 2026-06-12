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
                try hw.moveAodCompute(sequence.moveable);
                try hw.moveAodStorage(sequence.moveable);
                try hw.moveSlmStorage(sequence.fixed);
            }
        }

        // U gates fire last: within a stage, CZs precede the U barrier,
        // and by now all atoms are back at their storage positions.
        const pulses = try gpa.alloc(schedule.RamanGate, stage.u_gates.items.len);
        defer gpa.free(pulses);

        for (stage.u_gates.items, pulses) |gate, *p| {
            p.* = .{
                .qubit = gate.qubit,
                .angle = gate.theta,
                .phase = gate.phi,
            };
        }
        try hw.raman(pulses);
    }

    try hw.moveReadout();

    try hw.measure(.readout);

    return hw;
}

test {
    std.testing.refAllDecls(@This());
}
