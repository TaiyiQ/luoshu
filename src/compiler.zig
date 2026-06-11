//! Pass driver: runs the back-end over the front-end's stages.
//!
//! For each stage: route (CZ interaction graph -> logical Sequence), then
//! schedule (choreograph the sequence onto Hardware frames). This is the
//! only file that sees the whole pipeline; circuit, route, and schedule
//! do not import each other:
//!
//!     arch <- schedule <- compiler -> route
//!                                  -> circuit
const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const circuit = @import("circuit");
const route = @import("route");
const schedule = @import("schedule");

/// Route one stage's CZ gates: build the interaction graph and compile it
/// into a logical Sequence. Caller owns the result.
pub fn routeStage(gpa: std.mem.Allocator, cz_gates: []const circuit.Cz, num_qubits: usize) !route.Sequence {
    var g = try route.Graph.init(gpa, num_qubits, false);
    defer g.deinit();

    for (cz_gates) |gate| try g.addEdge(gate.control, gate.target);

    return route.compile(gpa, &g);
}

/// Compile a staged circuit into a hardware schedule.
pub fn compile(gpa: std.mem.Allocator, pipe: *const circuit.Pipeline, cfg: arch.ArchConfig) !schedule.Hardware {
    var hw = try schedule.Hardware.init(gpa, cfg, pipe.num_qubits);
    errdefer hw.deinit();

    for (pipe.stages.items) |*stage| {
        // A stage with no CZ gates has nothing to route (route.compile
        // rejects an edgeless graph), so it is pure Raman pulses.
        if (stage.cz_gates.items.len > 0) {
            var sequence = try routeStage(gpa, stage.cz_gates.items, pipe.num_qubits);
            defer sequence.deinit();
            // Silent in tests: any test-step stderr gets displayed by the
            // build runner under a misleading "failed command:" banner.
            if (builtin.mode == .Debug and !builtin.is_test) sequence.print();

            try hw.moveSlmCompute(sequence.fixed);
            try hw.moveAodCompute(sequence.moveable);
            try hw.moveAodStorage(sequence.moveable);
            try hw.moveSlmStorage(sequence.fixed);
        }

        // U gates fire last: within a stage CZs precede the U barrier,
        // and by now all atoms are back at their storage positions.
        const pulses = try gpa.alloc(schedule.RamanGate, stage.u_gates.items.len);
        defer gpa.free(pulses);
        for (stage.u_gates.items, pulses) |gate, *p| {
            p.* = .{ .qubit = @intCast(gate.qubit), .angle = gate.theta, .phase = gate.phi };
        }
        try hw.raman(pulses);
    }

    // Terminal readout: shuttle all qubits to the readout zone and image.
    try hw.moveReadout();
    try hw.measure(.readout);

    return hw;
}

test {
    @import("testutil").refAllDeclsRecursive(@This());
}
