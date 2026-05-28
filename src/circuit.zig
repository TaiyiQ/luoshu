const std = @import("std");

const PI = std.math.pi;

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

    pub fn parse(self: *QasmParser) !Circuit {
        defer self.registers.deinit(self.allocator);
        try self.collectDeclarations();
        self.pos = 0;
        var circ = Circuit.init(self.allocator, self.total_qubits);
        errdefer circ.deinit();
        try self.parseGates(&circ);
        return circ;
    }

    fn skipWs(self: *QasmParser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    fn skipWsAndComments(self: *QasmParser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                    } else break;
                },
                else => break,
            }
        }
    }

    fn skipToSemicolon(self: *QasmParser) void {
        while (self.pos < self.src.len and self.src[self.pos] != ';') {
            if (self.src[self.pos] == '"') {
                self.pos += 1;
                while (self.pos < self.src.len and self.src[self.pos] != '"') self.pos += 1;
                if (self.pos < self.src.len) self.pos += 1;
            } else self.pos += 1;
        }
        if (self.pos < self.src.len) self.pos += 1;
    }

    fn readIdent(self: *QasmParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') self.pos += 1 else break;
        }
        return self.src[start..self.pos];
    }

    fn readUint(self: *QasmParser) !usize {
        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        if (start == self.pos) return error.ParseError;
        return std.fmt.parseInt(usize, self.src[start..self.pos], 10);
    }

    fn consume(self: *QasmParser, c: u8) !void {
        self.skipWs();
        if (self.pos >= self.src.len or self.src[self.pos] != c) return error.ParseError;
        self.pos += 1;
    }

    fn findRegister(self: *QasmParser, name: []const u8) ?usize {
        for (self.registers.items) |reg| {
            if (std.mem.eql(u8, reg.name, name)) return reg.base;
        }
        return null;
    }

    fn scanPhysicalQubits(self: *QasmParser) void {
        var i: usize = 0;
        while (i < self.src.len) {
            if (self.src[i] == '$') {
                i += 1;
                const start = i;
                while (i < self.src.len and std.ascii.isDigit(self.src[i])) i += 1;
                if (i > start) {
                    if (std.fmt.parseInt(usize, self.src[start..i], 10)) |idx| {
                        if (idx + 1 > self.total_qubits) self.total_qubits = idx + 1;
                    } else |_| {}
                }
            } else i += 1;
        }
    }

    fn collectDeclarations(self: *QasmParser) !void {
        self.scanPhysicalQubits();
        while (self.pos < self.src.len) {
            self.skipWsAndComments();
            if (self.pos >= self.src.len) break;
            const word = self.readIdent();
            if (word.len == 0) {
                self.pos += 1;
                continue;
            }
            if (std.mem.eql(u8, word, "qubit")) {
                self.skipWs();
                try self.consume('[');
                const n = try self.readUint();
                try self.consume(']');
                self.skipWs();
                const name = self.readIdent();
                try self.registers.append(self.allocator, .{ .name = name, .base = self.total_qubits });
                self.total_qubits += n;
            }
            self.skipToSemicolon();
        }
    }

    fn parseQubitRef(self: *QasmParser) !usize {
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '$') {
            self.pos += 1;
            return try self.readUint();
        }
        const name = self.readIdent();
        try self.consume('[');
        const idx = try self.readUint();
        try self.consume(']');
        const base = self.findRegister(name) orelse return error.UnknownRegister;
        return base + idx;
    }

    const ExprError = error{ ParseError, InvalidCharacter };

    fn parseExpr(self: *QasmParser) ExprError!f64 {
        return self.parseAddSub();
    }

    fn parseAddSub(self: *QasmParser) ExprError!f64 {
        var val = try self.parseMulDiv();
        while (true) {
            self.skipWs();
            if (self.pos >= self.src.len) break;
            switch (self.src[self.pos]) {
                '+' => {
                    self.pos += 1;
                    val += try self.parseMulDiv();
                },
                '-' => {
                    self.pos += 1;
                    val -= try self.parseMulDiv();
                },
                else => break,
            }
        }
        return val;
    }

    fn parseMulDiv(self: *QasmParser) ExprError!f64 {
        var val = try self.parsePrimary();
        while (true) {
            self.skipWs();
            if (self.pos >= self.src.len) break;
            switch (self.src[self.pos]) {
                '*' => {
                    self.pos += 1;
                    val *= try self.parsePrimary();
                },
                '/' => {
                    self.pos += 1;
                    val /= try self.parsePrimary();
                },
                else => break,
            }
        }
        return val;
    }

    fn parsePrimary(self: *QasmParser) ExprError!f64 {
        self.skipWs();
        if (self.pos >= self.src.len) return error.ParseError;

        if (self.src[self.pos] == '-') {
            self.pos += 1;
            return -(try self.parsePrimary());
        }
        if (self.src[self.pos] == '(') {
            self.pos += 1;
            const val = try self.parseExpr();
            try self.consume(')');
            return val;
        }
        if (std.ascii.isAlphabetic(self.src[self.pos])) {
            const word = self.readIdent();
            if (std.mem.eql(u8, word, "pi")) return PI;
            return error.ParseError;
        }

        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c) or c == '.') {
                self.pos += 1;
            } else if ((c == 'e' or c == 'E') and self.pos > start) {
                self.pos += 1;
                if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            } else break;
        }
        if (start == self.pos) return error.ParseError;
        return std.fmt.parseFloat(f64, self.src[start..self.pos]);
    }

    fn parseGates(self: *QasmParser, circ: *Circuit) !void {
        while (self.pos < self.src.len) {
            self.skipWsAndComments();
            if (self.pos >= self.src.len) break;
            const word = self.readIdent();
            if (word.len == 0) {
                self.pos += 1;
                continue;
            }

            if (std.mem.eql(u8, word, "OPENQASM") or
                std.mem.eql(u8, word, "include") or
                std.mem.eql(u8, word, "qubit") or
                std.mem.eql(u8, word, "bit"))
            {
                self.skipToSemicolon();
            } else if (std.mem.eql(u8, word, "h")) {
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.h(q);
            } else if (std.mem.eql(u8, word, "x")) {
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.x(q);
            } else if (std.mem.eql(u8, word, "y")) {
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.y(q);
            } else if (std.mem.eql(u8, word, "z")) {
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.z(q);
            } else if (std.mem.eql(u8, word, "rx")) {
                try self.consume('(');
                const theta = try self.parseExpr();
                try self.consume(')');
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.rx(q, theta);
            } else if (std.mem.eql(u8, word, "ry")) {
                try self.consume('(');
                const theta = try self.parseExpr();
                try self.consume(')');
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.ry(q, theta);
            } else if (std.mem.eql(u8, word, "rz")) {
                try self.consume('(');
                const angle = try self.parseExpr();
                try self.consume(')');
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.rz(q, angle);
            } else if (std.mem.eql(u8, word, "u")) {
                try self.consume('(');
                const theta = try self.parseExpr();
                try self.consume(',');
                const phi = try self.parseExpr();
                try self.consume(',');
                const lambda = try self.parseExpr();
                try self.consume(')');
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.u(q, theta, phi, lambda);
            } else if (std.mem.eql(u8, word, "r")) {
                try self.consume('(');
                const theta = try self.parseExpr();
                try self.consume(',');
                const phi = try self.parseExpr();
                try self.consume(')');
                const q = try self.parseQubitRef();
                try self.consume(';');
                // r(θ,φ) = U(θ, -π/2+φ, π/2-φ)
                try circ.u(q, theta, -PI / 2.0 + phi, PI / 2.0 - phi);
            } else if (std.mem.eql(u8, word, "cz")) {
                const control = try self.parseQubitRef();
                try self.consume(',');
                const target = try self.parseQubitRef();
                try self.consume(';');
                try circ.cz(control, target);
            } else if (std.mem.eql(u8, word, "cx")) {
                const control = try self.parseQubitRef();
                try self.consume(',');
                const target = try self.parseQubitRef();
                try self.consume(';');
                try circ.cx(control, target);
            } else if (std.mem.eql(u8, word, "sx")) {
                const q = try self.parseQubitRef();
                try self.consume(';');
                try circ.sx(q);
            } else {
                self.skipToSemicolon();
            }
        }
    }
};

pub const Native = union(enum) {
    u: struct {
        qubit: usize,
        theta: f64,
        phi: f64,
        lambda: f64,
    },
    cz: struct {
        control: usize,
        target: usize,
    },
};

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

    pub fn deinit(self: *Circuit) void {
        self.gates.deinit(self.allocator);
    }

    pub fn h(self: *Circuit, q: usize) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI / 2.0,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn x(self: *Circuit, q: usize) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn y(self: *Circuit, q: usize) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI,
            .phi = PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }

    pub fn z(self: *Circuit, q: usize) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = 0.0,
            .phi = 0.0,
            .lambda = PI,
        } });
    }

    pub fn rx(self: *Circuit, q: usize, theta: f64) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = -PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }

    pub fn ry(self: *Circuit, q: usize, theta: f64) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = 0.0,
            .lambda = 0.0,
        } });
    }

    pub fn rz(self: *Circuit, q: usize, angle: f64) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = 0.0,
            .phi = 0.0,
            .lambda = angle,
        } });
    }

    pub fn u(self: *Circuit, q: usize, theta: f64, phi: f64, lambda: f64) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = theta,
            .phi = phi,
            .lambda = lambda,
        } });
    }

    pub fn cz(self: *Circuit, control: usize, target: usize) !void {
        try self.gates.append(self.allocator, .{ .cz = .{
            .control = control,
            .target = target,
        } });
    }

    pub fn cx(self: *Circuit, control: usize, target: usize) !void {
        try self.h(target);
        try self.cz(control, target);
        try self.h(target);
    }

    pub fn sx(self: *Circuit, q: usize) !void {
        try self.gates.append(self.allocator, .{ .u = .{
            .qubit = q,
            .theta = PI / 2.0,
            .phi = -PI / 2.0,
            .lambda = PI / 2.0,
        } });
    }
};
