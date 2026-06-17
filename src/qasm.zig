//! OpenQASM front-end: the only module that knows QASM syntax. Lexes and
//! parses a `.qasm` source into a `circuit.Circuit` via the builder API,
//! lowering each statement to native U/CZ gates. Depends on `circuit` (the
//! IR) and std; nothing reads back into the parser.
//! https://openqasm.com/versions/3.0/index.html

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
    return loadDiag(gpa, io, path, &diag, null);
}

/// Like `load`, but on a parse error writes a located `Diagnostic` to `diag`
/// (left untouched on I/O errors, which carry no source location), and appends
/// any non-fatal warnings to `warnings` when a list is supplied. `warnings` is
/// caller-owned; its `Diagnostic`s hold no slices into the source.
pub fn loadDiag(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    diag: *?Diagnostic,
    warnings: ?*std.ArrayList(Diagnostic),
) !Circuit {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    const reader = &fr.interface;

    // Reads everything to EOF into allocator-owned memory.
    const src = try reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(src);

    var parser = QasmParser.init(gpa, src);
    parser.warn_sink = warnings;
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
    // Optional, caller-owned sink for non-fatal warnings (e.g. a discarded
    // measurement). Left null when the caller does not collect warnings.
    warn_sink: ?*std.ArrayList(Diagnostic),
    // Qubits already measured, by flat index, for re-measurement and
    // use-after-measurement warnings. Only populated when warnings are
    // collected (see `markMeasured`).
    measured: std.AutoHashMap(u32, void),

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
            .warn_sink = null,
            .measured = std.AutoHashMap(u32, void).init(gpa),
        };
    }

    // Records `reason` and raises a parse error. The location is recovered
    // later from `pos`, which sits at the offending token.
    fn fail(s: *QasmParser, reason: []const u8) error{ParseError} {
        s.reason = reason;
        return error.ParseError;
    }

    // Appends a located, non-fatal warning at byte offset `at` when a sink is
    // set; a no-op otherwise. Dropping a warning on allocation failure is
    // harmless, so the append error is ignored.
    fn warn(s: *QasmParser, at: usize, reason: []const u8) void {
        const sink = s.warn_sink orelse return;
        const loc = lineCol(s.src, at);
        sink.append(s.gpa, .{ .reason = reason, .line = loc.line, .col = loc.col }) catch {};
    }

    // Records qubit `q` as measured. A no-op (and no allocation) when warnings
    // are not collected, since the set only feeds warnings; dropping an entry
    // on allocation failure merely misses a warning, which is harmless.
    fn markMeasured(s: *QasmParser, q: u32) void {
        if (s.warn_sink == null) return;
        s.measured.put(q, {}) catch {};
    }

    fn isMeasured(s: *QasmParser, q: u32) bool {
        return s.warn_sink != null and s.measured.contains(q);
    }

    pub fn parse(s: *QasmParser) !Circuit {
        defer s.reg.deinit(s.gpa);
        defer s.bits.deinit(s.gpa);
        defer s.measured.deinit();

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

    // Requires the next token to be `c`. On a miss the diagnostic names the
    // expected delimiter and points just past the previous token (where it
    // should be), rather than at whatever was found instead.
    fn consume(s: *QasmParser, c: u8) !void {
        const after_prev = s.pos;
        s.skipWs();
        if (s.pos >= s.src.len or s.src[s.pos] != c) {
            s.pos = after_prev;
            return s.fail(switch (c) {
                '[' => "expected '['",
                ']' => "expected ']'",
                '(' => "expected '('",
                ')' => "expected ')'",
                ',' => "expected ','",
                ';' => "expected ';'",
                else => "unexpected token",
            });
        }
        s.pos += 1;
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

    // A register name is unique across both namespaces, so a redeclaration —
    // qubit or bit, same kind or not — collides with an earlier one.
    fn declared(s: *QasmParser, name: []const u8) bool {
        return s.qubitReg(name) != null or s.bitRegWidth(name) != null;
    }

    // Validates the qubit operand of a `measure`, flags that the program
    // produces a readout, records the measured qubits, and returns how many it
    // measures: 1 for an indexed (`q[0]`) or physical (`$0`) qubit, or the
    // register width for a whole register (`q`). Anything else — notably
    // `measure[q]`, which is not valid OpenQASM — errors. The measurement is
    // not added to the IR (it carries no readout), so this is a syntax/width
    // check plus measurement tracking; the caller consumes the rest of the
    // statement, including any `-> bit` target. `stmt_at` locates warnings.
    fn parseMeasureOperand(s: *QasmParser, stmt_at: usize) !usize {
        s.skipWs();
        var first: u32 = 0; // flat index of the first measured qubit
        var count: usize = 1; // a physical or indexed qubit is a single qubit
        if (s.pos < s.src.len and s.src[s.pos] == '$') {
            s.pos += 1;
            first = @intCast(try s.readUint());
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
                const idx = try s.readUint();
                try s.consume(']');
                if (idx >= reg.width) return s.fail("qubit index out of range");
                first = @intCast(reg.base + idx);
            } else {
                first = @intCast(reg.base);
                count = reg.width; // a whole register measures all its qubits
            }
        }
        s.saw_measure = true;

        // Track the measured qubits; warn once if any was already measured.
        var remeasured = false;
        for (0..count) |k| {
            const q = first + @as(u32, @intCast(k));
            if (s.isMeasured(q)) remeasured = true;
            s.markMeasured(q);
        }
        if (remeasured) s.warn(stmt_at, "qubit measured more than once");

        return count;
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
    // The bit index is bounds-checked only once the statement is confirmed to
    // be a measurement, so a non-measuring `c[5] = ...` never errors here.
    fn assignmentMeasure(s: *QasmParser, name: []const u8) !?MeasureLhs {
        s.skipWs();
        var indexed = false;
        var idx: usize = 0;
        var idx_at: usize = 0;
        // An optional index on the classical target, e.g. `c[0] = ...`.
        if (s.pos < s.src.len and s.src[s.pos] == '[') {
            indexed = true;
            s.pos += 1;
            s.skipWs();
            idx_at = s.pos;
            // A non-numeric index (e.g. a loop variable) is not a form we
            // model: treat the statement as a non-measuring assignment.
            idx = s.readUint() catch return null;
            s.skipWs();
            if (s.pos >= s.src.len or s.src[s.pos] != ']') return null;
            s.pos += 1;
            s.skipWs();
        }
        if (s.pos >= s.src.len or s.src[s.pos] != '=') return null;
        s.pos += 1;
        s.skipWsAndComments();
        if (!std.mem.eql(u8, s.readIdent(), "measure")) return null;
        // Confirmed a measuring assignment: the index now must be in range.
        if (indexed) {
            if (s.bitRegWidth(name)) |w| {
                if (idx >= w) {
                    s.pos = idx_at; // point the diagnostic at the index
                    return s.fail("bit index out of range");
                }
            }
        }
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
            const decl_at = s.pos;
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
                if (name.len == 0) return s.fail("expected a register name");
                try s.consume(';');
                // A redeclaration is dropped (the first binding wins); warn so
                // its qubits don't silently go unallocated.
                if (s.declared(name)) {
                    s.warn(decl_at, "register redeclared");
                } else {
                    try s.reg.append(s.gpa, .{ .name = name, .base = s.total_qubits, .width = n });
                    s.total_qubits += n;
                }
                continue;
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
                if (name.len == 0) return s.fail("expected a register name");
                try s.consume(';');
                if (s.declared(name))
                    s.warn(decl_at, "register redeclared")
                else
                    try s.bits.append(s.gpa, .{ .name = name, .width = width });
                continue;
            }
            s.skipToSemicolon();
        }
    }

    fn parseQubitRef(s: *QasmParser) !u32 {
        s.skipWs();
        const at = s.pos;
        const q: u32 = blk: {
            if (s.pos < s.src.len and s.src[s.pos] == '$') {
                s.pos += 1;
                break :blk @intCast(try s.readUint());
            }
            const name = s.readIdent();
            try s.consume('[');
            const idx = try s.readUint();
            try s.consume(']');
            const reg = s.qubitReg(name) orelse return error.UnknownRegister;
            if (idx >= reg.width) return s.fail("qubit index out of range");
            break :blk @intCast(reg.base + idx);
        };
        if (s.isMeasured(q)) s.warn(at, "operation on an already-measured qubit");
        return q;
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
            const stmt_start = s.pos;
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
                // A two-qubit gate on one qubit is ill-formed: the operands
                // must be distinct qubits.
                if (control == target) {
                    s.pos = stmt_start;
                    return s.fail("two-qubit gate on a single qubit");
                }
                try circ.cz(control, target);
            } else if (std.mem.eql(u8, word, "cx")) {
                const control = try s.parseQubitRef();
                try s.consume(',');
                const target = try s.parseQubitRef();
                try s.consume(';');
                if (control == target) {
                    s.pos = stmt_start;
                    return s.fail("two-qubit gate on a single qubit");
                }
                try circ.cx(control, target);
            } else if (std.mem.eql(u8, word, "sx")) {
                const q = try s.parseQubitRef();
                try s.consume(';');
                try circ.sx(q);
            } else if (std.mem.eql(u8, word, "measure")) {
                // Leading form: `measure q;` (result discarded) or
                // `measure q -> c;` (routed to a classical bit).
                _ = try s.parseMeasureOperand(stmt_start);
                s.skipWs();
                const routed = s.pos + 1 < s.src.len and s.src[s.pos] == '-' and s.src[s.pos + 1] == '>';
                if (!routed) s.warn(stmt_start, "measurement result is discarded");
                s.skipToSemicolon();
            } else if (try s.assignmentMeasure(word)) |lhs| {
                // Assignment form: `c = measure q;` (the leading `word` was
                // the classical target). The number of qubits measured must
                // match the target bit register's width, so e.g. measuring a
                // whole register into a single bit, or a single qubit into a
                // wider register, is a mismatch.
                const qubits = try s.parseMeasureOperand(stmt_start);
                if (lhs.width) |bits| {
                    if (qubits != bits)
                        return s.fail("measurement width does not match the target bit register");
                }
                s.skipToSemicolon();
            } else if (isIgnorableDirective(word)) {
                // Safe to drop: these don't change the measured result, so a
                // warning suffices.
                s.warn(stmt_start, "directive ignored");
                s.skipToSemicolon();
            } else {
                // Everything else is an operation we cannot faithfully compile.
                // Dropping it would emit a schedule that doesn't match the
                // source, so this is an error, not a warning. Offer a spelling
                // hint when the word is a near-miss of a keyword — but not for
                // an assignment (`c[0] = …`), where the leading word is a real
                // target name used classically, not a mistyped gate.
                s.pos = stmt_start;
                if (!s.isAssignmentStmt(stmt_start)) {
                    if (nearestKeyword(word)) |hint| return s.fail(hint);
                }
                if (isUnsupportedConstruct(word)) return s.fail("unsupported OpenQASM construct");
                return s.fail("unrecognized statement");
            }
        }
    }

    // True when the statement beginning at `from` contains an `=` before its
    // terminator — i.e. it assigns to its leading identifier (a classical op
    // we don't model) rather than calling it like a gate. The arrow form
    // `measure q -> c;` never reaches here, so a bare `=` is unambiguous.
    fn isAssignmentStmt(s: *QasmParser, from: usize) bool {
        var i = from;
        while (i < s.src.len and s.src[i] != ';') : (i += 1) {
            if (s.src[i] == '=') return true;
        }
        return false;
    }

    // Directives with no effect on the measured result: dropping them is safe,
    // so they warn rather than error. (`gphase` is a global phase; `barrier`
    // and `delay` are scheduling/timing hints this compiler does not model.)
    fn isIgnorableDirective(word: []const u8) bool {
        const kws = [_][]const u8{ "barrier", "delay", "gphase" };
        for (kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
        return false;
    }

    // OpenQASM keywords this compiler recognizes but cannot compile, named so
    // the error reads as "unsupported" rather than "unrecognized" (a typo or
    // unknown gate). Dropping any of these would change the result.
    fn isUnsupportedConstruct(word: []const u8) bool {
        const kws = [_][]const u8{
            "if",  "for", "while", "gate", "def",
            "defcal", "cal", "reset", "box", "creg", "qreg",
        };
        for (kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
        return false;
    }

    // Keywords worth suggesting when a leading word is a near-miss. Each
    // carries its full hint so the (static) message needs no allocation, and
    // gates read as "unknown gate" while the rest read as "unrecognized
    // statement". Members of a gate family (the controlled gates, the
    // rotations) share a hint that lists all of them, since a typo like `c`
    // or `r` is equally close to each. Single-char gates (`h`, `x`, …) are
    // omitted: at one edit they collide with too much to guess usefully.
    const Suggestion = struct { word: []const u8, hint: []const u8 };
    fn suggestStmt(comptime w: []const u8) Suggestion {
        return .{ .word = w, .hint = "unrecognized statement; did you mean '" ++ w ++ "'?" };
    }
    fn suggestGate(comptime w: []const u8, comptime hint: []const u8) Suggestion {
        return .{ .word = w, .hint = "unknown gate; did you mean " ++ hint ++ "?" };
    }
    const suggestions = [_]Suggestion{
        suggestStmt("qubit"), suggestStmt("bit"), suggestStmt("measure"), suggestStmt("include"),
        suggestGate("cx", "'cx' or 'cz'"), suggestGate("cz", "'cx' or 'cz'"),
        suggestGate("rx", "'rx', 'ry', or 'rz'"), suggestGate("ry", "'rx', 'ry', or 'rz'"), suggestGate("rz", "'rx', 'ry', or 'rz'"),
        suggestGate("sx", "'sx'"),
    };

    // Returns a "did you mean …?" hint when `word` is within one edit of a
    // suggestable keyword, else null. The keyword must be at least 2 chars so
    // a single-char typo target doesn't collide spuriously. Ties favor the
    // earlier table entry.
    fn nearestKeyword(word: []const u8) ?[]const u8 {
        var best: ?Suggestion = null;
        var best_d: usize = std.math.maxInt(usize);
        for (suggestions) |s| {
            const d = editDistance(word, s.word);
            if (d < best_d) {
                best_d = d;
                best = s;
            }
        }
        if (best) |s| {
            if (best_d <= 1 and s.word.len >= 2) return s.hint;
        }
        return null;
    }

    // Levenshtein distance via a single rolling row. Caps inputs the buffer
    // can't hold (only short identifiers are ever compared here).
    fn editDistance(a: []const u8, b: []const u8) usize {
        var row: [64]usize = undefined;
        if (b.len + 1 > row.len) return std.math.maxInt(usize);
        for (0..b.len + 1) |j| row[j] = j;
        for (a, 0..) |ca, i| {
            var prev = row[0]; // distance for the previous diagonal cell
            row[0] = i + 1;
            for (b, 0..) |cb, j| {
                const above = row[j + 1];
                const cost: usize = if (ca == cb) 0 else 1;
                row[j + 1] = @min(@min(row[j + 1] + 1, row[j] + 1), prev + cost);
                prev = above;
            }
        }
        return row[b.len];
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

test "QasmParser warns when a measurement result is discarded" {
    var warns: std.ArrayList(Diagnostic) = .empty;
    defer warns.deinit(std.testing.allocator);

    // Bare `measure q;` on line 2 throws its result away.
    const src = "qubit[2] q;\nmeasure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    p.warn_sink = &warns;
    var circ = try p.parse();
    circ.deinit();

    try std.testing.expectEqual(1, warns.items.len);
    try std.testing.expectEqual(2, warns.items[0].line);
}

test "QasmParser does not warn when a measurement is routed to a bit" {
    var warns: std.ArrayList(Diagnostic) = .empty;
    defer warns.deinit(std.testing.allocator);

    // Both the arrow form and the assignment form keep the result. Distinct
    // registers keep this from also tripping the remeasurement warning.
    const src = "qubit[2] a;\nqubit[2] b;\nbit[2] c;\nmeasure a -> c;\nc = measure b;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    p.warn_sink = &warns;
    var circ = try p.parse();
    circ.deinit();

    try std.testing.expectEqual(0, warns.items.len);
}

test "QasmParser errors on an out-of-range qubit index" {
    // q[2] is out of range for a 2-qubit register.
    const gate = "qubit[2] q;\nh q[2];\nmeasure q;\n";
    var pg = QasmParser.init(std.testing.allocator, gate);
    try std.testing.expectError(error.ParseError, pg.parse());

    // Same check applies to a measured single qubit.
    const meas = "qubit[2] q;\nmeasure q[2];\n";
    var pm = QasmParser.init(std.testing.allocator, meas);
    try std.testing.expectError(error.ParseError, pm.parse());
}

test "QasmParser errors on an out-of-range bit index in a measurement target" {
    // c[5] is out of range for a 2-bit register.
    const src = "qubit[2] q;\nbit[2] c;\nc[5] = measure q[0];\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("bit index out of range", p.reason.?);
}

test "QasmParser does not bit-index-check a non-measuring assignment" {
    // `c[5]` is out of range, but this is not a measurement, so the bit-index
    // check must not fire. The statement is still unsupported, so it errors —
    // but as an unrecognized statement, not as a bit index out of range.
    const src = "qubit[2] q;\nbit[2] c;\nc[5] = q;\nmeasure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("unrecognized statement", p.reason.?);
}

test "QasmParser warns on (and drops) an ignorable directive" {
    var warns: std.ArrayList(Diagnostic) = .empty;
    defer warns.deinit(std.testing.allocator);

    // `barrier` has no effect on the measured result, so it is dropped with a
    // warning rather than erroring.
    const src = "qubit[2] q;\nbit[2] c;\ncz q[0], q[1];\nbarrier q;\nc = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    p.warn_sink = &warns;
    var circ = try p.parse();
    circ.deinit();

    try std.testing.expectEqual(1, warns.items.len);
    try std.testing.expectEqualStrings("directive ignored", warns.items[0].reason);
    try std.testing.expectEqual(4, warns.items[0].line);
}

test "QasmParser errors with a suggestion on a mistyped keyword" {
    // `it` is one edit from `bit`, so it is treated as a typo, not dropped.
    const src = "it[8] c;\nmeasure c;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("unrecognized statement; did you mean 'bit'?", p.reason.?);

    // A mistyped `measure` is caught the same way rather than silently dropped.
    const meas = "qubit[2] q;\nmeasur q;\n";
    var pm = QasmParser.init(std.testing.allocator, meas);
    try std.testing.expectError(error.ParseError, pm.parse());
    try std.testing.expectEqualStrings("unrecognized statement; did you mean 'measure'?", pm.reason.?);

    // A mistyped two-qubit gate reads as an unknown gate with a guess — even
    // when `c` is also a declared register, since the gate-shaped call (no
    // `=`) is not an assignment to that register.
    const cgate = "qubit[3] q;\nbit[3] c;\nc q[1], q[2];\nmeasure q;\n";
    var pc = QasmParser.init(std.testing.allocator, cgate);
    try std.testing.expectError(error.ParseError, pc.parse());
    try std.testing.expectEqualStrings("unknown gate; did you mean 'cx' or 'cz'?", pc.reason.?);
}

test "QasmParser errors on an operation it cannot compile" {
    // An unknown gate would change the circuit if dropped, so it errors. Far
    // from any keyword, it gets no spelling suggestion.
    const swap = "qubit[2] q;\nswap q[0], q[1];\nmeasure q;\n";
    var ps = QasmParser.init(std.testing.allocator, swap);
    try std.testing.expectError(error.ParseError, ps.parse());
    try std.testing.expectEqualStrings("unrecognized statement", ps.reason.?);

    // A recognized-but-unsupported construct errors with its own message.
    const reset = "qubit[2] q;\nreset q;\nmeasure q;\n";
    var pr = QasmParser.init(std.testing.allocator, reset);
    try std.testing.expectError(error.ParseError, pr.parse());
    try std.testing.expectEqualStrings("unsupported OpenQASM construct", pr.reason.?);
}

test "QasmParser errors on a two-qubit gate on a single qubit" {
    // A self-targeting CZ/CX is ill-formed: its operands must differ.
    const cz = "qubit[2] q;\ncz q[0], q[0];\nmeasure q;\n";
    var pz = QasmParser.init(std.testing.allocator, cz);
    try std.testing.expectError(error.ParseError, pz.parse());
    try std.testing.expectEqualStrings("two-qubit gate on a single qubit", pz.reason.?);

    const cx = "qubit[2] q;\ncx q[1], q[1];\nmeasure q;\n";
    var px = QasmParser.init(std.testing.allocator, cx);
    try std.testing.expectError(error.ParseError, px.parse());
}

test "QasmParser names the missing delimiter in a declaration" {
    // Missing the closing ']'.
    const close = "qubit[8 q;\nmeasure q;\n";
    var pc = QasmParser.init(std.testing.allocator, close);
    try std.testing.expectError(error.ParseError, pc.parse());
    try std.testing.expectEqualStrings("expected ']'", pc.reason.?);

    // Missing the opening '['.
    const open = "qubit 8] q;\nmeasure q;\n";
    var po = QasmParser.init(std.testing.allocator, open);
    try std.testing.expectError(error.ParseError, po.parse());
    try std.testing.expectEqualStrings("expected '['", po.reason.?);
}

test "QasmParser errors on a declaration missing its semicolon" {
    // `qubit[8] q` with no terminating ';'.
    const at_eof = "qubit[8] q\n";
    var pe = QasmParser.init(std.testing.allocator, at_eof);
    try std.testing.expectError(error.ParseError, pe.parse());
    try std.testing.expectEqualStrings("expected ';'", pe.reason.?);

    // The following statement must not be silently swallowed in place of the
    // missing ';'.
    const before_stmt = "qubit[2] q\nmeasure q;\n";
    var pn = QasmParser.init(std.testing.allocator, before_stmt);
    try std.testing.expectError(error.ParseError, pn.parse());
}

test "QasmParser warns on a redeclared register" {
    var warns: std.ArrayList(Diagnostic) = .empty;
    defer warns.deinit(std.testing.allocator);

    const src = "qubit[2] q;\nqubit[3] q;\nbit[2] c;\nc = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    p.warn_sink = &warns;
    var circ = try p.parse();
    defer circ.deinit();

    // The first declaration wins (2 qubits); the second is dropped with a warn.
    try std.testing.expectEqual(2, circ.n);
    try std.testing.expectEqual(1, warns.items.len);
    try std.testing.expectEqualStrings("register redeclared", warns.items[0].reason);
    try std.testing.expectEqual(2, warns.items[0].line);
}

test "QasmParser warns on operating after measurement and on remeasurement" {
    var warns: std.ArrayList(Diagnostic) = .empty;
    defer warns.deinit(std.testing.allocator);

    // measure q (both qubits) → h q[0] is post-measure → measure q[1] is a
    // second measurement of an already-measured qubit. Both measurements are
    // routed so only the use-after/remeasure warnings remain.
    const src = "qubit[2] q;\nbit[2] c;\nmeasure q -> c;\nh q[0];\nmeasure q[1] -> c[1];\n";
    var p = QasmParser.init(std.testing.allocator, src);
    p.warn_sink = &warns;
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(2, warns.items.len);
    try std.testing.expectEqualStrings("operation on an already-measured qubit", warns.items[0].reason);
    try std.testing.expectEqualStrings("qubit measured more than once", warns.items[1].reason);
}

test "QasmParser does not warn on measurement tracking in legal order" {
    var warns: std.ArrayList(Diagnostic) = .empty;
    defer warns.deinit(std.testing.allocator);

    // All gates precede the measurement, and each qubit is measured once.
    const src = "qubit[2] q;\nbit[2] c;\nh q[0];\ncz q[0], q[1];\nc = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    p.warn_sink = &warns;
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(0, warns.items.len);
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
