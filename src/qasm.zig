//! OpenQASM front-end: the only module that knows QASM syntax. Lexes and
//! parses a `.qasm` source into a `circuit.Circuit` via the builder API,
//! lowering each statement to native U/CZ gates. Depends on `circuit` (the
//! IR) and std; nothing reads back into the parser.

const std = @import("std");
const circuit = @import("circuit");

const Circuit = circuit.Circuit;
const PI = std.math.pi;

/// A parse failure located in the source: a static `reason` plus the 1-based
/// line/column it occurred at. Carries no slices into the source, so it stays
/// valid after the source buffer is freed.
pub const Diagnostic = struct {
    reason: []const u8,
    line: usize,
    col: usize,
};

/// Loads and parses an OpenQASM circuit from a file.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Circuit {
    var diag: ?Diagnostic = null;
    return loadDiag(gpa, io, path, &diag);
}

/// Like `load`, but on a parse error writes a located `Diagnostic` to `diag`
/// (left untouched on I/O errors, which carry no source location).
pub fn loadDiag(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diag: *?Diagnostic) !Circuit {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    const reader = &fr.interface;

    // Reads everything to EOF into allocator-owned memory.
    const src = try reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(src);

    var parser = QasmParser.init(gpa, src);
    return parser.parse() catch |err| {
        const loc = lineCol(src, parser.pos);
        diag.* = .{
            .reason = parser.reason orelse defaultReason(err),
            .line = loc.line,
            .col = loc.col,
        };
        return err;
    };
}

/// The 1-based line and column of byte offset `pos` within `src`.
fn lineCol(src: []const u8, pos: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    const end = @min(pos, src.len);
    for (src[0..end]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

/// A fallback reason for errors raised without a specific `reason` message.
fn defaultReason(err: anyerror) []const u8 {
    return switch (err) {
        error.NoMeasurement => "circuit has no measurement",
        error.UnknownRegister => "reference to an undeclared register",
        error.InvalidCharacter, error.Overflow => "invalid numeric literal",
        error.ParseError => "invalid syntax",
        else => "could not parse circuit",
    };
}

pub const QasmParser = struct {
    const Register = struct { name: []const u8, base: usize, width: usize };
    const BitReg = struct { name: []const u8, width: usize };

    gpa: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    reg: std.ArrayList(Register),
    // Classical bit registers, tracked only to width-check measurements.
    bits: std.ArrayList(BitReg),
    total_qubits: usize,
    saw_measure: bool,
    // A static, human-readable reason for the most recent failure, when the
    // generic error name (e.g. "ParseError") is not specific enough. `load`
    // pairs it with the source location computed from `pos`.
    reason: ?[]const u8,

    pub fn init(gpa: std.mem.Allocator, src: []const u8) QasmParser {
        return .{
            .gpa = gpa,
            .src = src,
            .pos = 0,
            .reg = .empty,
            .bits = .empty,
            .total_qubits = 0,
            .saw_measure = false,
            .reason = null,
        };
    }

    // Records `reason` and raises a parse error. The location is recovered
    // later from `pos`, which sits at the offending token.
    fn fail(s: *QasmParser, reason: []const u8) error{ParseError} {
        s.reason = reason;
        return error.ParseError;
    }

    pub fn parse(s: *QasmParser) !Circuit {
        defer s.reg.deinit(s.gpa);
        defer s.bits.deinit(s.gpa);

        try s.collectDeclarations();

        s.pos = 0;
        var circ = Circuit.init(s.gpa, s.total_qubits);
        errdefer circ.deinit();

        try s.parseGates(&circ);

        // A program with no readout is not a runnable circuit. `saw_measure`
        // is set by parseGates as it validates each `measure` statement.
        if (!s.saw_measure) return error.NoMeasurement;

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
        for (s.reg.items) |reg| {
            if (std.mem.eql(u8, reg.name, name)) return reg.base;
        }
        return null;
    }

    fn qubitReg(s: *QasmParser, name: []const u8) ?Register {
        for (s.reg.items) |reg| {
            if (std.mem.eql(u8, reg.name, name)) return reg;
        }
        return null;
    }

    fn bitRegWidth(s: *QasmParser, name: []const u8) ?usize {
        for (s.bits.items) |b| {
            if (std.mem.eql(u8, b.name, name)) return b.width;
        }
        return null;
    }

    // Validates the qubit operand of a `measure`, flags that the program
    // produces a readout, and returns how many qubits it measures: 1 for an
    // indexed (`q[0]`) or physical (`$0`) qubit, or the register width for a
    // whole register (`q`). Anything else — notably `measure[q]`, which is not
    // valid OpenQASM — errors. The measurement is not added to the IR (it
    // carries no readout), so this is purely a syntax/width check; the caller
    // consumes the rest of the statement, including any `-> bit` target.
    fn parseMeasureOperand(s: *QasmParser) !usize {
        s.skipWs();
        var width: usize = 1; // a physical or indexed qubit is a single qubit
        if (s.pos < s.src.len and s.src[s.pos] == '$') {
            s.pos += 1;
            _ = try s.readUint();
        } else {
            const name = s.readIdent();
            if (name.len == 0) return s.fail("expected a qubit to measure, e.g. `measure q;`");
            const reg = s.qubitReg(name) orelse {
                s.reason = "measurement of an undeclared register";
                return error.UnknownRegister;
            };
            s.skipWs();
            if (s.pos < s.src.len and s.src[s.pos] == '[') {
                s.pos += 1;
                _ = try s.readUint();
                try s.consume(']');
            } else width = reg.width; // a whole register measures all its qubits
        }
        s.saw_measure = true;
        return width;
    }

    // The classical target of a measuring assignment. `width` is its bit
    // count — 1 for a single bit (`c[0]`, indexed) or the declared register
    // width for a whole register (`c`) — or null when the target register was
    // not declared, so its width is unknown and the caller skips the check.
    const MeasureLhs = struct { width: ?usize };

    // Probes whether the current statement is `<target>[idx]? = measure ...`,
    // with the target identifier (`name`) already consumed by the caller.
    // Returns null if it is not a measuring assignment; otherwise describes the
    // target and leaves pos just past `measure` so the operand can be parsed.
    fn assignmentMeasure(s: *QasmParser, name: []const u8) ?MeasureLhs {
        s.skipWs();
        var indexed = false;
        // An optional index on the classical target, e.g. `c[0] = ...`.
        if (s.pos < s.src.len and s.src[s.pos] == '[') {
            indexed = true;
            while (s.pos < s.src.len and s.src[s.pos] != ']' and s.src[s.pos] != ';') s.pos += 1;
            if (s.pos < s.src.len and s.src[s.pos] == ']') s.pos += 1;
            s.skipWs();
        }
        if (s.pos >= s.src.len or s.src[s.pos] != '=') return null;
        s.pos += 1;
        s.skipWsAndComments();
        if (!std.mem.eql(u8, s.readIdent(), "measure")) return null;
        return .{ .width = if (indexed) 1 else s.bitRegWidth(name) };
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
                try s.reg.append(s.gpa, .{ .name = name, .base = s.total_qubits, .width = n });
                s.total_qubits += n;
            } else if (std.mem.eql(u8, word, "bit")) {
                // `bit[n] c;` declares an n-wide register; `bit c;` a single
                // bit. Recorded only so measurements can be width-checked.
                s.skipWs();
                var width: usize = 1;
                if (s.pos < s.src.len and s.src[s.pos] == '[') {
                    s.pos += 1;
                    width = try s.readUint();
                    try s.consume(']');
                }
                s.skipWs();
                const name = s.readIdent();
                if (name.len != 0) try s.bits.append(s.gpa, .{ .name = name, .width = width });
            }
            s.skipToSemicolon();
        }
    }

    fn parseQubitRef(s: *QasmParser) !u32 {
        s.skipWs();
        if (s.pos < s.src.len and s.src[s.pos] == '$') {
            s.pos += 1;
            return @intCast(try s.readUint());
        }
        const name = s.readIdent();
        try s.consume('[');
        const idx = try s.readUint();
        try s.consume(']');
        const base = s.findRegister(name) orelse return error.UnknownRegister;
        return @intCast(base + idx);
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
            } else if (std.mem.eql(u8, word, "measure")) {
                // Leading form: `measure q;` or `measure q -> c;`.
                _ = try s.parseMeasureOperand();
                s.skipToSemicolon();
            } else if (s.assignmentMeasure(word)) |lhs| {
                // Assignment form: `c = measure q;` (the leading `word` was
                // the classical target). The number of qubits measured must
                // match the target bit register's width, so e.g. measuring a
                // whole register into a single bit, or a single qubit into a
                // wider register, is a mismatch.
                const qubits = try s.parseMeasureOperand();
                if (lhs.width) |bits| {
                    if (qubits != bits)
                        return s.fail("measurement width does not match the target bit register");
                }
                s.skipToSemicolon();
            } else {
                s.skipToSemicolon();
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "QasmParser flattens a register and parses gate arguments" {
    const src =
        \\OPENQASM 3.0;
        \\include "stdgates.inc";
        \\qubit[2] q;
        \\bit[2] c;
        \\// comments and unknown statements are skipped
        \\ry(pi/2) q[0];
        \\cz q[0], q[1];
        \\c = measure q;
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(2, circ.n);
    try std.testing.expectEqual(2, circ.gates.items.len);

    const ry = circ.gates.items[0].u;
    try std.testing.expectEqual(0, ry.qubit);
    try std.testing.expectEqual(PI / 2.0, ry.theta);

    const cz_gate = circ.gates.items[1].cz;
    try std.testing.expectEqual(0, cz_gate.control);
    try std.testing.expectEqual(1, cz_gate.target);
}

test "QasmParser assigns later reg higher base indices" {
    const src =
        \\qubit[2] a;
        \\qubit[3] b;
        \\cz a[1], b[2];
        \\measure a[1];
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(5, circ.n);
    const cz_gate = circ.gates.items[0].cz;
    try std.testing.expectEqual(1, cz_gate.control);
    try std.testing.expectEqual(4, cz_gate.target);
}

test "QasmParser errors when the program never measures" {
    const src =
        \\qubit[2] q;
        \\cz q[0], q[1];
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.NoMeasurement, p.parse());
}

test "QasmParser rejects measure with a bracketed operand" {
    // `measure[q]` is not valid OpenQASM: the qubit operand follows the
    // keyword as `measure q`, it is not subscripted onto `measure`.
    const assign = "qubit[2] q;\nc = measure[q];\n";
    var pa = QasmParser.init(std.testing.allocator, assign);
    try std.testing.expectError(error.ParseError, pa.parse());

    const lead = "qubit[2] q;\nmeasure[q];\n";
    var pl = QasmParser.init(std.testing.allocator, lead);
    try std.testing.expectError(error.ParseError, pl.parse());
}

test "QasmParser accepts the assignment and arrow measure forms" {
    const assign = "qubit[2] q;\nbit[2] c;\nc = measure q;\n";
    var pa = QasmParser.init(std.testing.allocator, assign);
    var ca = try pa.parse();
    ca.deinit();

    const arrow = "qubit[2] q;\nmeasure q[0] -> c[0];\n";
    var pr = QasmParser.init(std.testing.allocator, arrow);
    var cr = try pr.parse();
    cr.deinit();

    // A single-bit target with a single-qubit operand matches in width.
    const indexed = "qubit[2] q;\nbit[2] c;\nc[1] = measure q[1];\n";
    var pi = QasmParser.init(std.testing.allocator, indexed);
    var ci = try pi.parse();
    ci.deinit();
}

test "QasmParser rejects measuring a register into a single bit" {
    // `c[1]` is one bit but `q` is the whole 2-qubit register: a width mismatch.
    const src = "qubit[2] q;\nbit[2] c;\nc[1] = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expect(p.reason != null);
}

test "QasmParser rejects a measurement narrower than its bit register" {
    // `c` is 6 bits but `q[1]` measures a single qubit: a width mismatch.
    const src = "qubit[2] q;\nbit[6] c;\nc = measure q[1];\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expect(p.reason != null);
}

test "QasmParser rejects a register measurement whose widths differ" {
    // Whole-register to whole-register, but 3 qubits into 2 bits.
    const src = "qubit[3] q;\nbit[2] c;\nc = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expect(p.reason != null);
}

test "lineCol maps byte offsets to 1-based line and column" {
    const src = "ab\ncde\n";
    const cases = [_]struct { pos: usize, line: usize, col: usize }{
        .{ .pos = 0, .line = 1, .col = 1 },
        .{ .pos = 1, .line = 1, .col = 2 },
        .{ .pos = 3, .line = 2, .col = 1 }, // just past '\n'
        .{ .pos = 5, .line = 2, .col = 3 },
    };
    for (cases) |c| {
        const loc = lineCol(src, c.pos);
        try std.testing.expectEqual(c.line, loc.line);
        try std.testing.expectEqual(c.col, loc.col);
    }
}

test "parser records the failure location at the offending token" {
    // The offending '[' sits at column 12 of line 2 ("c = measure[q];").
    const src = "qubit[2] q;\nc = measure[q];\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    const loc = lineCol(src, p.pos);
    try std.testing.expectEqual(2, loc.line);
    try std.testing.expectEqual(12, loc.col);
}

test "QasmParser lowers cx to H-CZ-H on the target" {
    const src =
        \\qubit[2] q;
        \\cx q[0], q[1];
        \\measure q;
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(3, circ.gates.items.len);
    try std.testing.expectEqual(1, circ.gates.items[0].u.qubit);
    try std.testing.expectEqual(0, circ.gates.items[1].cz.control);
    try std.testing.expectEqual(1, circ.gates.items[1].cz.target);
    try std.testing.expectEqual(1, circ.gates.items[2].u.qubit);
}

test {
    std.testing.refAllDecls(@This());
}
