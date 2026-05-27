const std = @import("std");

const PI = std.math.pi;

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
};

const Token = union(enum) {
    keyword: []const u8,
    identifier: []const u8,
    number: f64,
    symbol: u8,
    eof,
    invalid,
};

const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    fn next(self: *Lexer) Token {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.source.len and !(self.source[self.pos] == '*' and self.source[self.pos + 1] == '/')) self.pos += 1;
                self.pos += 2;
                continue;
            }
            break;
        }
        if (self.pos >= self.source.len) return .eof;
        const start = self.pos;
        const c = self.source[self.pos];
        if (std.ascii.isAlpha(c) or c == '_') {
            while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) self.pos += 1;
            const word = self.source[start..self.pos];
            const keywords = [_][]const u8{ "OPENQASM", "include", "qubit", "h", "x", "y", "z", "rz", "rx", "ry", "u", "cx" };
            for (keywords) |k| if (std.mem.eql(u8, word, k)) return .{ .keyword = word };
            return .{ .identifier = word };
        }
        if (std.ascii.isDigit(c) or c == '.' or c == '-') {
            while (self.pos < self.source.len and (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '.' or self.source[self.pos] == '-')) self.pos += 1;
            const num_str = self.source[start..self.pos];
            const num = std.fmt.parseFloat(f64, num_str) catch 0.0;
            return .{ .number = num };
        }
        self.pos += 1;
        return .{ .symbol = c };
    }
};

pub const QasmParser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token = undefined,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) QasmParser {
        return .{ .allocator = allocator, .lexer = .{ .source = source } };
    }

    fn eat(self: *QasmParser) void {
        self.current = self.lexer.next();
    }

    pub fn parse(self: *QasmParser) !Circuit {
        self.eat();
        var circuit: Circuit = undefined;
        var n_qubits: usize = 0;
        while (self.current != .eof) {
            if (self.current == .keyword and std.mem.eql(u8, self.current.keyword, "OPENQASM")) {
                self.eat();
                while (self.current != .symbol or self.current.symbol != ';') self.eat();
                self.eat();
                continue;
            }
            if (self.current == .keyword and std.mem.eql(u8, self.current.keyword, "include")) {
                self.eat();
                while (self.current != .symbol or self.current.symbol != ';') self.eat();
                self.eat();
                continue;
            }
            if (self.current == .keyword and std.mem.eql(u8, self.current.keyword, "qubit")) {
                self.eat();
                if (self.current == .symbol and self.current.symbol == '[') {
                    self.eat();
                    if (self.current == .number) {
                        n_qubits = @intFromFloat(self.current.number);
                        self.eat();
                    }
                    if (self.current == .symbol and self.current.symbol == ']') self.eat();
                } else n_qubits = 1;
                while (self.current != .symbol or self.current.symbol != ';') self.eat();
                self.eat();
                circuit = Circuit.init(self.allocator, n_qubits);
                continue;
            }
            if (self.current == .keyword) {
                const gate_name = self.current.keyword;
                self.eat();
                var theta: f64 = 0.0;
                var phi: f64 = 0.0;
                var lambda: f64 = 0.0;
                if (self.current == .symbol and self.current.symbol == '(') {
                    self.eat();
                    if (self.current == .number) {
                        theta = self.current.number;
                        self.eat();
                    }
                    if (self.current == .symbol and self.current.symbol == ',') {
                        self.eat();
                    }
                    if (self.current == .number) {
                        phi = self.current.number;
                        self.eat();
                    }
                    if (self.current == .symbol and self.current.symbol == ',') {
                        self.eat();
                    }
                    if (self.current == .number) {
                        lambda = self.current.number;
                        self.eat();
                    }
                    if (self.current == .symbol and self.current.symbol == ')') self.eat();
                }

                var qubits: [2]usize = undefined;
                var num_q: usize = 0;
                while (self.current != .symbol or self.current.symbol != ';') {
                    if (self.current == .identifier) self.eat();
                    if (self.current == .symbol and self.current.symbol == '[') {
                        self.eat();
                        if (self.current == .number) {
                            qubits[num_q] = @intFromFloat(self.current.number);
                            num_q += 1;
                            self.eat();
                        }
                        if (self.current == .symbol and self.current.symbol == ']') self.eat();
                    }
                    if (self.current == .symbol and self.current.symbol == ',') self.eat();
                }

                self.eat();

                if (std.mem.eql(u8, gate_name, "h"))
                    try circuit.h(qubits[0])
                else if (std.mem.eql(u8, gate_name, "x"))
                    try circuit.x(qubits[0])
                else if (std.mem.eql(u8, gate_name, "y"))
                    try circuit.y(qubits[0])
                else if (std.mem.eql(u8, gate_name, "z"))
                    try circuit.z(qubits[0])
                else if (std.mem.eql(u8, gate_name, "rz"))
                    try circuit.rz(qubits[0], theta)
                else if (std.mem.eql(u8, gate_name, "rx"))
                    try circuit.rx(qubits[0], theta)
                else if (std.mem.eql(u8, gate_name, "ry"))
                    try circuit.ry(qubits[0], theta)
                else if (std.mem.eql(u8, gate_name, "u"))
                    try circuit.u(qubits[0], theta, phi, lambda)
                else if (std.mem.eql(u8, gate_name, "cx"))
                    try circuit.cx(qubits[0], qubits[1]);
                continue;
            }

            self.eat();
        }

        return circuit;
    }
};

//pub fn main(init: std.process.Init) !void {
//    var c = Circuit.init(init.gpa, 4);
//    defer c.deinit();
//    try c.h(0);
//    try c.cx(0, 1);
//    try c.rz(2, 1.57);
//    try c.z(3);
//    try c.u(0, 0.1, 0.2, 0.3);
//
//    //    // Or load from OpenQASM (same native Circuit)
//    //    const qasm_source =
//    //        \\OPENQASM 3;
//    //        \\include "stdgates.inc";
//    //        \\qubit[4] q;
//    //        \\h q[0];
//    //        \\cx q[0], q[1];
//    //        \\rz(1.57) q[2];
//    //        \\z q[3];
//    //        \\u(0.1, 0.2, 0.3) q[0];
//    //
//    //    var parser = QasmParser.init(allocator, qasm_source);
//    //    var circuit = try parser.parse();
//    //    defer circuit.deinit();
//}
