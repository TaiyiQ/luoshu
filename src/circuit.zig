const std = @import("std");
const schedule = @import("schedule");
const route = @import("route");
const arch = @import("arch");
const rl = @import("raylib");

const PI = std.math.pi;

pub const U = struct {
    qubit: usize,
    theta: f64,
    phi: f64,
    lambda: f64,
};

pub const Cz = struct {
    control: usize,
    target: usize,
};

pub const Native = union(enum) {
    u: U,
    cz: Cz,
};

const Stage = struct {
    u_gates: std.ArrayList(U) = .empty,
    cz_gates: std.ArrayList(Cz) = .empty,

    fn deinit(s: *Stage, allocator: std.mem.Allocator) void {
        s.u_gates.deinit(allocator);
        s.cz_gates.deinit(allocator);
    }

    // Generate a graph connecting CZ qubits, to move them into the compute zone.
    // The stage owns the graph. Therefore, it compiles a logical sequence from
    // the CZ gates using a graph.
    pub fn compile(s: *Stage, allocator: std.mem.Allocator, num_qubit: usize) !route.Sequence {
        std.debug.print(">> Stage: compiling\n", .{});

        for (s.cz_gates.items) |gate| {
            std.debug.print("{any}\nn", .{gate});
        }

        var g = try route.Graph.init(allocator, num_qubit, false);
        defer g.deinit();

        for (s.cz_gates.items) |gate| try g.addEdge(gate.control, gate.target);

        const sequence = try route.compile(allocator, &g);
        //try sequence.writeToFile(s.allocator, init.io, "./zig-out/logical.json");
        sequence.print();

        return sequence;
    }
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    stages: std.ArrayList(Stage),
    num_qubits: usize,

    fn init(allocator: std.mem.Allocator, n: usize) !Pipeline {
        return .{
            .allocator = allocator,
            .stages = .empty,
            .num_qubits = n,
        };
    }

    pub fn deinit(s: *Pipeline) void {
        for (s.stages.items) |*stage| stage.deinit(s.allocator);
        s.stages.deinit(s.allocator);
    }

    // Place a `gate` into stage `n`, creating intervening stages as needed.
    fn place(s: *Pipeline, n: usize, gate: Native) !void {
        while (s.stages.items.len <= n) {
            try s.stages.append(s.allocator, .{});
        }
        const stage = &s.stages.items[n];
        switch (gate) {
            .u => |g| try stage.u_gates.append(s.allocator, g),
            .cz => |g| try stage.cz_gates.append(s.allocator, g),
        }
    }

    pub fn compile(s: *Pipeline, cfg: arch.ArchConfig) !schedule.Physical {
        var ops: std.ArrayList(schedule.Op) = .empty;

        // t = 0: SLM bulk move (storage → compute).
        const t_slm: u32 = 0;

        // t ≥ 1: one AOD move + Rydberg pulse per logical color, in order.
        const t_aod_base: u32 = t_slm + 1;

        var placement: []schedule.Point = &.{};
        var initial_placement: []schedule.Point = &.{};

        for (s.stages.items, 0..) |*stage, stage_idx| {
            var sequence = try stage.compile(s.allocator, s.num_qubits);
            defer sequence.deinit();

            if (stage_idx == 0) {
                placement = try schedule.qubitPlacement(
                    s.allocator,
                    cfg.storage_zone,
                    sequence.fixed,
                    sequence.moveable,
                    s.num_qubits,
                );
                initial_placement = try s.allocator.dupe(schedule.Point, placement);
            }

            try schedule.moveSlmCompute(
                s.allocator,
                cfg,
                sequence.fixed,
                &placement,
                &ops,
                t_slm,
            );

            // Rydberg after each move.
            try schedule.moveAodCompute(
                s.allocator,
                cfg.compute_zone,
                sequence.moveable,
                &placement,
                &ops,
                t_aod_base,
            );

            try schedule.moveAodStorage(
                s.allocator,
                sequence.moveable,
                initial_placement,
                &placement,
                &ops,
                t_aod_base + 1,
            );

            const t_slm_back = t_aod_base + 1 + @as(u32, @intCast(sequence.moveable.len));
            try schedule.moveSlmStorage(
                s.allocator,
                sequence.fixed,
                initial_placement,
                &placement,
                &ops,
                t_slm_back,
            );

            try schedule.addRamanOp(
                s.allocator,
                placement,
                stage.u_gates.items,
                t_aod_base,
                &ops,
            );
        }

        s.allocator.free(placement);

        const slots = try schedule.allSlmSlots(s.allocator, cfg);

        return .{
            .allocator = s.allocator,
            .ops = try ops.toOwnedSlice(s.allocator),
            .placement = initial_placement,
            .slots = slots,
        };
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
/// later of its two qubits' current stages.
///
/// Caller owns the result and must free it with `freeStages`.
pub fn decompose(allocator: std.mem.Allocator, c: Circuit) !Pipeline {
    //    var pipe: Pipeline = .{ .allocator = allocator };
    var pipe = try Pipeline.init(allocator, c.n);
    errdefer pipe.deinit();

    var map = std.AutoHashMap(usize, usize).init(allocator);
    defer map.deinit();
    for (0..c.n) |q| try map.put(q, 0);

    const Pending = struct { stage: usize, gate: Native };
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(allocator);

    for (c.gates.items) |gate| {
        switch (gate) {
            .u => |g| {
                const stage = map.get(g.qubit).?;
                try pending.append(allocator, .{ .stage = stage, .gate = gate });
                try map.put(g.qubit, stage + 1);
            },
            .cz => |g| {
                const stage = @max(map.get(g.control).?, map.get(g.target).?);
                try pipe.place(stage, gate);
            },
        }
    }

    for (pending.items) |p| try pipe.place(p.stage, p.gate);

    return pipe;
}

pub const Circuit = struct {
    allocator: std.mem.Allocator,
    gates: std.ArrayList(Native),
    n: usize,

    pub fn init(allocator: std.mem.Allocator, n_qubits: usize) Circuit {
        const gates: std.ArrayList(Native) = .empty;
        return .{
            .allocator = allocator,
            .gates = gates,
            .n = n_qubits,
        };
    }

    pub fn deinit(s: *Circuit) void {
        s.gates.deinit(s.allocator);
    }

    pub fn h(s: *Circuit, q: usize) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI / 2.0,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn x(s: *Circuit, q: usize) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn y(s: *Circuit, q: usize) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI,
            .phi = PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }

    pub fn z(s: *Circuit, q: usize) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = 0.0,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn rx(s: *Circuit, q: usize, theta: f64) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = -PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }

    pub fn ry(s: *Circuit, q: usize, theta: f64) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = 0.0,
            .lambda = 0.0,
        } });
    }

    pub fn rz(s: *Circuit, q: usize, angle: f64) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = 0.0,
            .phi = 0.0,
            .lambda = angle,
        } });
    }

    pub fn u(s: *Circuit, q: usize, theta: f64, phi: f64, lambda: f64) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = phi,
            .lambda = lambda,
        } });
    }

    pub fn cz(s: *Circuit, control: usize, target: usize) !void {
        try s.gates.append(s.allocator, .{ .cz = .{
            .control = control,
            .target = target,
        } });
    }

    pub fn cx(s: *Circuit, control: usize, target: usize) !void {
        try s.h(target);
        try s.cz(control, target);
        try s.h(target);
    }

    pub fn sx(s: *Circuit, q: usize) !void {
        try s.gates.append(s.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI / 2.0,
            .phi = -PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }
};

pub const QasmParser = struct {
    const Register = struct { name: []const u8, base: usize };

    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    registers: std.ArrayList(Register),
    total_qubits: usize,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) QasmParser {
        return .{
            .allocator = allocator,
            .src = src,
            .pos = 0,
            .registers = .empty,
            .total_qubits = 0,
        };
    }

    pub fn parse(s: *QasmParser) !Circuit {
        defer s.registers.deinit(s.allocator);
        try s.collectDeclarations();
        s.pos = 0;
        var circ = Circuit.init(s.allocator, s.total_qubits);
        errdefer circ.deinit();
        try s.parseGates(&circ);
        return circ;
    }

    fn skipWs(s: *QasmParser) void {
        while (s.pos < s.src.len) {
            switch (s.src[s.pos]) {
                ' ', '\t', '\n', '\r' => s.pos += 1,
                else => break,
            }
        }
    }

    fn skipWsAndComments(s: *QasmParser) void {
        while (s.pos < s.src.len) {
            switch (s.src[s.pos]) {
                ' ', '\t', '\n', '\r' => s.pos += 1,
                '/' => {
                    if (s.pos + 1 < s.src.len and s.src[s.pos + 1] == '/') {
                        while (s.pos < s.src.len and s.src[s.pos] != '\n') s.pos += 1;
                    } else break;
                },
                else => break,
            }
        }
    }

    fn skipToSemicolon(s: *QasmParser) void {
        while (s.pos < s.src.len and s.src[s.pos] != ';') {
            if (s.src[s.pos] == '"') {
                s.pos += 1;
                while (s.pos < s.src.len and s.src[s.pos] != '"') s.pos += 1;
                if (s.pos < s.src.len) s.pos += 1;
            } else s.pos += 1;
        }
        if (s.pos < s.src.len) s.pos += 1;
    }

    fn readIdent(s: *QasmParser) []const u8 {
        const start = s.pos;
        while (s.pos < s.src.len) {
            const c = s.src[s.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') s.pos += 1 else break;
        }
        return s.src[start..s.pos];
    }

    fn readUint(s: *QasmParser) !usize {
        const start = s.pos;
        while (s.pos < s.src.len and std.ascii.isDigit(s.src[s.pos])) s.pos += 1;
        if (start == s.pos) return error.ParseError;
        return std.fmt.parseInt(usize, s.src[start..s.pos], 10);
    }

    fn consume(s: *QasmParser, c: u8) !void {
        s.skipWs();
        if (s.pos >= s.src.len or s.src[s.pos] != c) return error.ParseError;
        s.pos += 1;
    }

    fn findRegister(s: *QasmParser, name: []const u8) ?usize {
        for (s.registers.items) |reg| {
            if (std.mem.eql(u8, reg.name, name)) return reg.base;
        }
        return null;
    }

    fn scanPhysicalQubits(s: *QasmParser) void {
        var i: usize = 0;
        while (i < s.src.len) {
            if (s.src[i] == '$') {
                i += 1;
                const start = i;
                while (i < s.src.len and std.ascii.isDigit(s.src[i])) i += 1;
                if (i > start) {
                    if (std.fmt.parseInt(usize, s.src[start..i], 10)) |idx| {
                        if (idx + 1 > s.total_qubits) s.total_qubits = idx + 1;
                    } else |_| {}
                }
            } else i += 1;
        }
    }

    fn collectDeclarations(s: *QasmParser) !void {
        s.scanPhysicalQubits();
        while (s.pos < s.src.len) {
            s.skipWsAndComments();
            if (s.pos >= s.src.len) break;
            const word = s.readIdent();
            if (word.len == 0) {
                s.pos += 1;
                continue;
            }
            if (std.mem.eql(u8, word, "qubit")) {
                s.skipWs();
                try s.consume('[');
                const n = try s.readUint();
                try s.consume(']');
                s.skipWs();
                const name = s.readIdent();
                try s.registers.append(s.allocator, .{ .name = name, .base = s.total_qubits });
                s.total_qubits += n;
            }
            s.skipToSemicolon();
        }
    }

    fn parseQubitRef(s: *QasmParser) !usize {
        s.skipWs();
        if (s.pos < s.src.len and s.src[s.pos] == '$') {
            s.pos += 1;
            return try s.readUint();
        }
        const name = s.readIdent();
        try s.consume('[');
        const idx = try s.readUint();
        try s.consume(']');
        const base = s.findRegister(name) orelse return error.UnknownRegister;
        return base + idx;
    }

    const ExprError = error{ ParseError, InvalidCharacter };

    fn parseExpr(s: *QasmParser) ExprError!f64 {
        return s.parseAddSub();
    }

    fn parseAddSub(s: *QasmParser) ExprError!f64 {
        var val = try s.parseMulDiv();
        while (true) {
            s.skipWs();
            if (s.pos >= s.src.len) break;
            switch (s.src[s.pos]) {
                '+' => {
                    s.pos += 1;
                    val += try s.parseMulDiv();
                },
                '-' => {
                    s.pos += 1;
                    val -= try s.parseMulDiv();
                },
                else => break,
            }
        }
        return val;
    }

    fn parseMulDiv(s: *QasmParser) ExprError!f64 {
        var val = try s.parsePrimary();
        while (true) {
            s.skipWs();
            if (s.pos >= s.src.len) break;
            switch (s.src[s.pos]) {
                '*' => {
                    s.pos += 1;
                    val *= try s.parsePrimary();
                },
                '/' => {
                    s.pos += 1;
                    val /= try s.parsePrimary();
                },
                else => break,
            }
        }
        return val;
    }

    fn parsePrimary(s: *QasmParser) ExprError!f64 {
        s.skipWs();
        if (s.pos >= s.src.len) return error.ParseError;

        if (s.src[s.pos] == '-') {
            s.pos += 1;
            return -(try s.parsePrimary());
        }
        if (s.src[s.pos] == '(') {
            s.pos += 1;
            const val = try s.parseExpr();
            try s.consume(')');
            return val;
        }
        if (std.ascii.isAlphabetic(s.src[s.pos])) {
            const word = s.readIdent();
            if (std.mem.eql(u8, word, "pi")) return PI;
            return error.ParseError;
        }

        const start = s.pos;
        while (s.pos < s.src.len) {
            const c = s.src[s.pos];
            if (std.ascii.isDigit(c) or c == '.') {
                s.pos += 1;
            } else if ((c == 'e' or c == 'E') and s.pos > start) {
                s.pos += 1;
                if (s.pos < s.src.len and (s.src[s.pos] == '+' or s.src[s.pos] == '-')) s.pos += 1;
            } else break;
        }
        if (start == s.pos) return error.ParseError;
        return std.fmt.parseFloat(f64, s.src[start..s.pos]);
    }

    fn parseGates(s: *QasmParser, circ: *Circuit) !void {
        while (s.pos < s.src.len) {
            s.skipWsAndComments();
            if (s.pos >= s.src.len) break;
            const word = s.readIdent();
            if (word.len == 0) {
                s.pos += 1;
                continue;
            }

            if (std.mem.eql(u8, word, "OPENQASM") or
                std.mem.eql(u8, word, "include") or
                std.mem.eql(u8, word, "qubit") or
                std.mem.eql(u8, word, "bit"))
            {
                s.skipToSemicolon();
            } else if (std.mem.eql(u8, word, "h")) {
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.h(q);
            } else if (std.mem.eql(u8, word, "x")) {
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.x(q);
            } else if (std.mem.eql(u8, word, "y")) {
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.y(q);
            } else if (std.mem.eql(u8, word, "z")) {
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.z(q);
            } else if (std.mem.eql(u8, word, "rx")) {
                try s.consume('(');
                const theta = try s.parseExpr();
                try s.consume(')');
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.rx(q, theta);
            } else if (std.mem.eql(u8, word, "ry")) {
                try s.consume('(');
                const theta = try s.parseExpr();
                try s.consume(')');
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.ry(q, theta);
            } else if (std.mem.eql(u8, word, "rz")) {
                try s.consume('(');
                const angle = try s.parseExpr();
                try s.consume(')');
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.rz(q, angle);
            } else if (std.mem.eql(u8, word, "u")) {
                try s.consume('(');
                const theta = try s.parseExpr();
                try s.consume(',');
                const phi = try s.parseExpr();
                try s.consume(',');
                const lambda = try s.parseExpr();
                try s.consume(')');
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.u(q, theta, phi, lambda);
            } else if (std.mem.eql(u8, word, "r")) {
                try s.consume('(');
                const theta = try s.parseExpr();
                try s.consume(',');
                const phi = try s.parseExpr();
                try s.consume(')');
                const q = try s.parseQubitRef();
                try s.consume(';');
                // r(θ,φ) = U(θ, -π/2+φ, π/2-φ)
                try circ.u(q, theta, -PI / 2.0 + phi, PI / 2.0 - phi);
            } else if (std.mem.eql(u8, word, "cz")) {
                const control = try s.parseQubitRef();
                try s.consume(',');
                const target = try s.parseQubitRef();
                try s.consume(';');
                try circ.cz(control, target);
            } else if (std.mem.eql(u8, word, "cx")) {
                const control = try s.parseQubitRef();
                try s.consume(',');
                const target = try s.parseQubitRef();
                try s.consume(';');
                try circ.cx(control, target);
            } else if (std.mem.eql(u8, word, "sx")) {
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.sx(q);
            } else {
                s.skipToSemicolon();
            }
        }
    }
};
