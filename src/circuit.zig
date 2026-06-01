const std = @import("std");
const rl = @import("raylib");

const PI = std.math.pi;

const U = struct {
    qubit: usize,
    theta: f64,
    phi: f64,
    lambda: f64,
};

const Cz = struct {
    control: usize,
    target: usize,
};

pub const Native = union(enum) {
    u: U,
    cz: Cz,
};

const Stages = std.ArrayList(std.ArrayList(Native));

/// Group the circuit's gates into stages, where a "stage" is a set of gates
/// that can run in parallel (no shared qubits within a stage).
///
/// CZ gates are diagonal and mutually commute, so any run of CZs with no
/// intervening U on a shared qubit forms one stage and may share qubits
/// freely. A U gate is a barrier: it advances its qubit to the next stage.
/// Within a stage, CZ gate indices are listed first, then U gate indices.
///
/// Returns a `Stages` = list of stages, indexed by stage number. Each stage is
/// itself a list of gate indices into `c.gates.items`. Within a stage, the CZ
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
pub fn decompose(allocator: std.mem.Allocator, c: Circuit) !Stages {
    var stages: Stages = .empty;

    // A map that keeps track of what stage a qubit is on.
    // Every qubit starts on stage 0.
    var map = std.AutoHashMap(usize, usize).init(allocator);
    defer map.deinit();
    for (0..c.n) |q| try map.put(q, 0);

    // U gates are buffered, then flushed into their stages after the CZ pass, so
    // each stage lists its CZ gates first and its U gates afterwards.
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
                // Grow stages on demand.
                while (stages.items.len <= stage) try stages.append(allocator, .empty);
                try stages.items[stage].append(allocator, gate);
            },
        }
    }

    // Flush U gates after all CZ gates have been placed.
    for (pending.items) |p| {
        try stages.items[p.stage].append(allocator, p.gate);
    }

    return stages;
}

pub fn freeStages(allocator: std.mem.Allocator, stages: *Stages) void {
    for (stages.items) |*stage| {
        stage.deinit(allocator);
    }
    stages.deinit(allocator);
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

fn wireY(q: usize, dy: f32, y_offset: f32) f32 {
    const fq: f32 = @floatFromInt(q);
    return fq * dy + dy + y_offset;
}

fn drawGate(gate: Native, x: f32, dy: f32, y_offset: f32, font_size: i32) void {
    const box: f32 = 40;
    const radius: f32 = 8;
    switch (gate) {
        .u => |u| {
            const qy = wireY(u.qubit, dy, y_offset);
            rl.drawRectangleV(
                .{ .x = x - box / 2, .y = qy - box / 2 },
                .{ .x = box, .y = box },
                .dark_purple,
            );
            rl.drawText("U", @intFromFloat(x - 6), @intFromFloat(qy - 10), font_size, .white);
        },
        .cz => |cz| {
            const cy = wireY(cz.control, dy, y_offset);
            const ty = wireY(cz.target, dy, y_offset);
            rl.drawLineV(.{ .x = x, .y = cy }, .{ .x = x, .y = ty }, .dark_gray);
            rl.drawCircleV(.{ .x = x, .y = cy }, radius, .dark_gray);
            rl.drawCircleLinesV(.{ .x = x, .y = ty }, radius, .dark_gray);
            rl.drawLineV(.{ .x = x - radius, .y = ty }, .{ .x = x + radius, .y = ty }, .dark_gray);
            rl.drawLineV(.{ .x = x, .y = ty - radius }, .{ .x = x, .y = ty + radius }, .dark_gray);
        },
    }
}

/// Draw the circuit. Pass `stages` to group gates into labelled, divided
/// columns; pass `null` to lay every gate out flat in order.
pub fn draw(c: Circuit, stages: ?Stages) !void {
    const screenWidth = 800;
    const screenHeight = 450;
    rl.initWindow(screenWidth, screenHeight, "circuit");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const sw: f32 = @floatFromInt(screenWidth);
    const sh: f32 = @floatFromInt(screenHeight);
    const num_qubits: f32 = @floatFromInt(c.n);
    const font_size: i32 = 20;

    const dy: f32 = sh / (num_qubits + 1);
    const x_offset: f32 = @floatFromInt(3 * font_size);
    const y_offset: f32 = font_size / 2;
    const col_w: f32 = 60;

    const total_cols: usize = c.gates.items.len; // one column per gate
    const content_w: f32 = @as(f32, @floatFromInt(total_cols)) * col_w;
    const max_scroll: f32 = @max(0, content_w - (sw - x_offset));

    var scroll: f32 = 0;

    while (!rl.windowShouldClose()) {
        scroll -= rl.getMouseWheelMove() * 30;
        if (rl.isKeyDown(.k)) scroll += 8;
        if (rl.isKeyDown(.j)) scroll -= 8;
        scroll = std.math.clamp(scroll, 0, max_scroll);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.ray_white);

        var buf: [32]u8 = undefined;

        // Wires.
        for (0..c.n) |q| {
            const y = wireY(q, dy, y_offset);
            rl.drawLineV(.{ .x = x_offset, .y = y }, .{ .x = sw, .y = y }, .dark_gray);
        }

        // Gates. The column index `col` advances per gate either way; the only
        // difference with stages is the divider + label drawn at each group's start.
        const colX = struct {
            fn at(col: usize, cw: f32, xo: f32, s: f32) f32 {
                return xo + (@as(f32, @floatFromInt(col)) + 0.5) * cw - s;
            }
        }.at;

        var col: usize = 0;
        if (stages) |st| {
            for (st.items, 0..) |stage, s| {
                const stage_x0 = x_offset + @as(f32, @floatFromInt(col)) * col_w - scroll;
                if (s > 0) rl.drawLineV(.{ .x = stage_x0, .y = 0 }, .{ .x = stage_x0, .y = sh }, .light_gray);
                const slabel = try std.fmt.bufPrintZ(&buf, "S{d}", .{s});
                rl.drawText(slabel, @intFromFloat(stage_x0 + 4), 4, font_size, .gray);

                for (stage.items) |gate| {
                    drawGate(gate, colX(col, col_w, x_offset, scroll), dy, y_offset, font_size);
                    col += 1;
                }
            }
        } else {
            for (c.gates.items) |gate| {
                drawGate(gate, colX(col, col_w, x_offset, scroll), dy, y_offset, font_size);
                col += 1;
            }
        }

        // Pinned qubit labels (mask the gutter first).
        rl.drawRectangle(0, 0, @intFromFloat(x_offset), screenHeight, .ray_white);
        for (0..c.n) |q| {
            const y: f32 = @as(f32, @floatFromInt(q)) * dy + dy;
            const str = try std.fmt.bufPrintZ(&buf, "q{d}", .{q});
            rl.drawText(str, font_size, @intFromFloat(y), font_size, .dark_gray);
        }

        // Scrollbar (only when overflowing).
        if (max_scroll > 0) {
            const track_y: f32 = sh - 16;
            const track_w: f32 = sw - x_offset;
            const thumb_w: f32 = @max(30, track_w * (track_w / content_w));
            const thumb_x: f32 = x_offset + (scroll / max_scroll) * (track_w - thumb_w);
            rl.drawRectangle(@intFromFloat(x_offset), @intFromFloat(track_y), @intFromFloat(track_w), 12, .light_gray);
            rl.drawRectangle(@intFromFloat(thumb_x), @intFromFloat(track_y), 12, 12, .gray);
            const m = rl.getMousePosition();
            if (rl.isMouseButtonDown(.left) and m.y >= track_y - 4) {
                const frac = std.math.clamp((m.x - x_offset - thumb_w / 2) / (track_w - thumb_w), 0, 1);
                scroll = frac * max_scroll;
            }
        }
    }
}
