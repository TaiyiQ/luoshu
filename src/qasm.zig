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
        // Prefer the location captured at failure time; fall back to the
        // cursor for errors raised without one.
        const at = parser.err_pos orelse parser.absPos(parser.pos);
        const loc = lineCol(src, at);
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
    const Register = struct {
        name: []const u8,
        base: usize,
        width: usize,
    };

    const BitReg = struct {
        name: []const u8,
        width: usize,
    };

    // A named classical value (a `const`/variable or a `for` loop variable).
    // All classical types — int, float, angle, … — are evaluated to f64;
    // subscripts and loop bounds round to an integer. `vars` is a scope
    // stack: a lookup scans from the end, so inner bindings (loop variables)
    // shadow outer ones.
    const NamedVal = struct { name: []const u8, value: f64 };

    gpa: std.mem.Allocator,
    // The source slice currently being parsed. At the top level this is the
    // whole program; during a gate/def/loop expansion it is the body slice,
    // always a contiguous sub-slice of `source` (see `absPos`).
    src: []const u8,
    // The original, full program source, kept so diagnostics emitted while a
    // body is expanded still report a position in the file the user wrote.
    source: []const u8,
    pos: usize,
    reg: std.ArrayList(Register),
    // Classical bit registers, tracked only to width-check measurements.
    bits: std.ArrayList(BitReg),
    // Classical scope stack: `const`s, variables, and `for` loop variables.
    // `parsePrimary` resolves a bare identifier against it.
    vars: std.ArrayList(NamedVal),
    // Nesting depth of loop expansion, guarding against deep nesting
    // (which would otherwise overflow the stack).
    expand_depth: usize,
    total_qubits: usize,
    saw_measure: bool,
    // A static, human-readable reason for the most recent failure, when the
    // generic error name (e.g. "ParseError") is not specific enough. `load`
    // pairs it with the source location.
    reason: ?[]const u8,
    // The absolute source offset of the failure, captured when it is raised
    // (before the expansion stack unwinds and restores `src`/`pos`). Without
    // it, an error inside a gate/def/loop body would be located against the
    // wrong slice. Null until a located failure occurs.
    err_pos: ?usize,
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
            .source = src,
            .pos = 0,
            .reg = .empty,
            .bits = .empty,
            .vars = .empty,
            .expand_depth = 0,
            .total_qubits = 0,
            .saw_measure = false,
            .reason = null,
            .err_pos = null,
            .warn_sink = null,
            .measured = std.AutoHashMap(u32, void).init(gpa),
        };
    }

    // Records `reason` and the absolute failure location, then raises a parse
    // error. Capturing the location now (rather than from `pos` afterward) keeps
    // it correct even when the failure is inside an expanded body, which the
    // unwinding restores out from under `pos`.
    fn fail(s: *QasmParser, reason: []const u8) error{ParseError} {
        return s.failWith(error.ParseError, reason);
    }

    // Like `fail`, but raises `err` instead of the generic ParseError.
    fn failWith(s: *QasmParser, err: anytype, reason: []const u8) @TypeOf(err) {
        s.reason = reason;
        s.err_pos = s.absPos(s.pos);
        return err;
    }

    // Appends a located, non-fatal warning at byte offset `at` when a sink is
    // set; a no-op otherwise. Dropping a warning on allocation failure is
    // harmless, so the append error is ignored.
    fn warn(s: *QasmParser, at: usize, reason: []const u8) void {
        const sink = s.warn_sink orelse return;
        const loc = lineCol(s.source, s.absPos(at));
        sink.append(s.gpa, .{ .reason = reason, .line = loc.line, .col = loc.col }) catch {};
    }

    // Maps an offset within the current `src` (which, during a gate/def/loop
    // expansion, is a body slice) to an offset in the original `source`. Every
    // body is a contiguous sub-slice of the source, so pointer arithmetic
    // recovers the absolute position for a diagnostic.
    fn absPos(s: *QasmParser, at: usize) usize {
        return @intFromPtr(s.src.ptr) - @intFromPtr(s.source.ptr) + at;
    }

    // Records qubit `q` as measured. A no-op (and no allocation) when warnings
    // are not collected, since the set only feeds warnings; dropping an entry
    // on allocation failure merely misses a warning, which is harmless.
    fn markMeasured(s: *QasmParser, q: u32) void {
        if (s.warn_sink == null) return;
        s.measured.put(q, {}) catch {};
    }

    // Clears the measured flag for `count` qubits from `base`: a `reset` returns
    // them to a fresh state, so a later operation on them must not warn as if
    // they were still measured.
    fn unmarkMeasured(s: *QasmParser, base: u32, count: usize) void {
        if (s.warn_sink == null) return;
        for (0..count) |k| _ = s.measured.remove(base + @as(u32, @intCast(k)));
    }

    fn isMeasured(s: *QasmParser, q: u32) bool {
        return s.warn_sink != null and s.measured.contains(q);
    }

    pub fn parse(s: *QasmParser) !Circuit {
        defer s.reg.deinit(s.gpa);
        defer s.bits.deinit(s.gpa);
        defer s.measured.deinit();
        defer s.vars.deinit(s.gpa);

        try s.collectDeclarations();

        // The declaration pass evaluated top-level `const`s only to size
        // registers (`qubit[N]`); the gate pass re-evaluates them in order, so
        // start it from a clean scope.
        s.vars.clearRetainingCapacity();
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

    // Parses a qubit operand that may cover a range: a physical (`$0`) or
    // indexed (`q[0]`) qubit — a single qubit, the index a constant expression
    // — or a whole register (`q`, all its qubits). `missing` and `undeclared`
    // name the statement in the two operand diagnostics.
    const QubitRange = struct { base: u32, count: usize };
    fn parseQubitRange(s: *QasmParser, missing: []const u8, undeclared: []const u8) !QubitRange {
        s.skipWs();
        if (s.pos < s.src.len and s.src[s.pos] == '$') {
            s.pos += 1;
            return .{ .base = @intCast(try s.readUint()), .count = 1 };
        }
        const name = s.readIdent();
        if (name.len == 0) return s.fail(missing);
        const reg = s.qubitReg(name) orelse return s.failWith(error.UnknownRegister, undeclared);
        s.skipWs();
        if (s.pos < s.src.len and s.src[s.pos] == '[') {
            s.pos += 1;
            const idx = try s.evalIndex();
            try s.consume(']');
            if (idx >= reg.width) return s.fail("qubit index out of range");
            return .{ .base = @intCast(reg.base + idx), .count = 1 };
        }
        return .{ .base = @intCast(reg.base), .count = reg.width };
    }

    // Validates the qubit operand of a `measure`, flags that the program
    // produces a readout, records the measured qubits, and returns how many it
    // measures. Anything else — notably `measure[q]`, which is not valid
    // OpenQASM — errors. The measurement is not added to the IR (it carries no
    // readout), so this is a syntax/width check plus measurement tracking; the
    // caller consumes the rest of the statement, including any `-> bit`
    // target. `stmt_at` locates warnings.
    fn parseMeasureOperand(s: *QasmParser, stmt_at: usize) !usize {
        const r = try s.parseQubitRange(
            "expected a qubit to measure, e.g. `measure q;`",
            "measurement of an undeclared register",
        );
        s.saw_measure = true;

        // Track the measured qubits; warn once if any was already measured.
        var remeasured = false;
        for (0..r.count) |k| {
            const q = r.base + @as(u32, @intCast(k));
            if (s.isMeasured(q)) remeasured = true;
            s.markMeasured(q);
        }
        if (remeasured) s.warn(stmt_at, "qubit measured more than once");

        return r.count;
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
            // The index is a constant expression (a literal, or e.g. a loop
            // variable); anything that doesn't evaluate is not a form we
            // model, so treat the statement as a non-measuring assignment.
            idx = s.evalIndex() catch return null;
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
            var word = s.readIdent();
            if (word.len == 0) {
                s.pos += 1;
                continue;
            }
            // `input`/`output` are declaration modifiers; the real declaration
            // keyword follows.
            if (std.mem.eql(u8, word, "input") or std.mem.eql(u8, word, "output")) {
                s.skipWs();
                word = s.readIdent();
            }
            if (std.mem.eql(u8, word, "qubit")) {
                // `qubit[n] q;` declares an n-wide register; `qubit q;` a
                // single qubit.
                s.skipWs();
                var n: usize = 1;
                if (s.pos < s.src.len and s.src[s.pos] == '[') {
                    s.pos += 1;
                    n = try s.readWidth();
                    try s.consume(']');
                }
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
                // bit. A `bit b = measure q;` form also initializes it; that
                // measurement is handled in the gate pass, so the initializer
                // is skipped here. Recorded only so measurements can be
                // width-checked.
                s.skipWs();
                var width: usize = 1;
                if (s.pos < s.src.len and s.src[s.pos] == '[') {
                    s.pos += 1;
                    width = try s.readWidth();
                    try s.consume(']');
                }
                s.skipWs();
                const name = s.readIdent();
                if (name.len == 0) return s.fail("expected a register name");
                s.skipWs();
                if (s.pos < s.src.len and s.src[s.pos] == '=')
                    s.skipToSemicolon()
                else
                    try s.consume(';');
                if (s.declared(name))
                    s.warn(decl_at, "register redeclared")
                else
                    try s.bits.append(s.gpa, .{ .name = name, .width = width });
                continue;
            } else if (std.mem.eql(u8, word, "const") or isClassicalType(word)) {
                // Evaluate a top-level classical declaration so that a later
                // register width may reference it, e.g. `const int N = 9;`
                // followed by `qubit[N] q;`.
                try s.evalClassicalDecl(word);
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
            const reg = s.qubitReg(name) orelse {
                s.pos = at;
                return s.failWith(error.UnknownRegister, "reference to an undeclared register");
            };
            s.skipWs();
            // `q[i]` indexes the register; a bare `q` names the only qubit of a
            // single-qubit register. The index is a constant expression (e.g.
            // `qs[j + 1]` inside a loop), evaluated and rounded to an integer.
            if (s.pos < s.src.len and s.src[s.pos] == '[') {
                s.pos += 1;
                const idx = try s.evalIndex();
                try s.consume(']');
                if (idx >= reg.width) return s.fail("qubit index out of range");
                break :blk @intCast(reg.base + idx);
            }
            if (reg.width != 1) return s.fail("a multi-qubit register needs an index");
            break :blk @intCast(reg.base);
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
        if (std.ascii.isAlphabetic(s.src[s.pos]) or s.src[s.pos] == '_') {
            const id_start = s.pos;
            const word = s.readIdent();
            if (std.mem.eql(u8, word, "pi")) return PI;
            if (std.mem.eql(u8, word, "tau")) return 2.0 * PI;
            if (std.mem.eql(u8, word, "euler")) return std.math.e;
            // A `const`, variable, `def` parameter, or `for` loop variable.
            if (s.lookupVar(word)) |v| return v;
            s.err_pos = s.absPos(id_start);
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

    // Resolves a classical identifier against the scope stack, innermost first,
    // so a loop variable shadows an outer binding of the same name. Null when
    // the name is not a bound classical value.
    fn lookupVar(s: *QasmParser, name: []const u8) ?f64 {
        var i = s.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, s.vars.items[i].name, name)) return s.vars.items[i].value;
        }
        return null;
    }

    // Classical scalar types whose declarations bind a value into `vars`. `bit`
    // and `qubit` are excluded: they declare registers, handled separately.
    fn isClassicalType(word: []const u8) bool {
        const kws = [_][]const u8{
            "int",  "uint",     "float",   "double",  "angle",
            "bool", "duration", "stretch", "complex",
        };
        for (kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
        return false;
    }

    // Evaluates a register width or array size: a constant expression that
    // usually is a literal but may reference a `const` (e.g. `qubit[N]`).
    // Rounded to a non-negative integer.
    fn readWidth(s: *QasmParser) !usize {
        const v = try s.parseExpr();
        if (v < 0) return s.fail("negative register width");
        return @intFromFloat(@round(v));
    }

    // Evaluates a subscript expression (e.g. `qs[j + 1]`) to a non-negative
    // index. Negative results are rejected by the caller's bounds check.
    fn evalIndex(s: *QasmParser) !usize {
        const v = try s.parseExpr();
        if (v < 0) return s.fail("negative qubit index");
        return @intFromFloat(@round(v));
    }

    // Evaluates an integer expression used as a `for` loop bound, rounding to
    // the nearest integer.
    fn evalInt(s: *QasmParser) !i64 {
        return @intFromFloat(@round(try s.parseExpr()));
    }

    // Parses a classical declaration whose leading word (`const` or a scalar
    // type) is already read: `[const] TYPE[ [size] ] name [= expr];`. When an
    // initializer is present its value is bound in the current scope; an
    // uninitialized declaration is accepted but binds nothing.
    fn evalClassicalDecl(s: *QasmParser, leading: []const u8) !void {
        var tword = leading;
        if (std.mem.eql(u8, tword, "const")) {
            s.skipWs();
            tword = s.readIdent();
        }
        // An optional bit-size on the type, e.g. `int[32]`; not modeled.
        s.skipWs();
        if (s.pos < s.src.len and s.src[s.pos] == '[') {
            while (s.pos < s.src.len and s.src[s.pos] != ']') s.pos += 1;
            if (s.pos < s.src.len) s.pos += 1;
        }
        s.skipWs();
        const name = s.readIdent();
        if (name.len == 0) return s.fail("expected a variable name");
        s.skipWs();
        if (s.pos < s.src.len and s.src[s.pos] == '=') {
            s.pos += 1;
            const save = s.pos;
            if (s.parseExpr()) |v| {
                try s.vars.append(s.gpa, .{ .name = name, .value = v });
            } else |_| {
                s.pos = save;
                return s.fail("initializer is not a constant expression");
            }
        }
        s.skipToSemicolon();
    }

    // Parses `for TYPE v in [a:b]` or `[a:step:b] { body }` (the `for` already
    // consumed) and unrolls it, binding `v` to each value of the inclusive
    // range and re-parsing the body for each. The bounds are constant integer
    // expressions, so they may reference `const`s and enclosing loop variables.
    fn parseForLoop(
        s: *QasmParser,
        circ: *Circuit,
    ) error{ ParseError, InvalidCharacter, Overflow, UnknownRegister, OutOfMemory }!void {
        if (s.expand_depth >= 64) return s.fail("loop nesting too deep");
        s.skipWs();
        _ = s.readIdent(); // the loop variable's type, e.g. `int`
        s.skipWs();
        const varname = s.readIdent();
        if (varname.len == 0) return s.fail("expected a loop variable name");
        s.skipWs();
        if (!std.mem.eql(u8, s.readIdent(), "in")) return s.fail("expected 'in' in a for loop");

        try s.consume('[');
        const start = try s.evalInt();
        try s.consume(':');
        const second = try s.evalInt();
        var step: i64 = 1;
        var stop = second;
        s.skipWs();
        if (s.pos < s.src.len and s.src[s.pos] == ':') {
            // `[a:step:b]`: the middle value was the step.
            s.pos += 1;
            step = second;
            stop = try s.evalInt();
        }
        try s.consume(']');
        if (step == 0) return s.fail("for loop step is zero");

        const body = try s.captureBlock();
        const after = s.pos;

        var k = start;
        while (if (step > 0) k <= stop else k >= stop) : (k += step) {
            try s.vars.append(s.gpa, .{ .name = varname, .value = @floatFromInt(k) });
            const saved_src = s.src;
            s.src = body;
            s.pos = 0;
            s.expand_depth += 1;
            defer {
                s.expand_depth -= 1;
                s.src = saved_src;
                _ = s.vars.pop();
            }
            try s.parseGates(circ);
        }
        s.pos = after;
    }

    // Consumes a brace-delimited block at the cursor and returns the source
    // between its braces, leaving the cursor just past the closing `}`. Tracks
    // nesting so inner braces are included.
    fn captureBlock(s: *QasmParser) ![]const u8 {
        s.skipWs();
        if (s.pos >= s.src.len or s.src[s.pos] != '{') return s.fail("expected '{' to open a block");
        s.pos += 1;
        const body_start = s.pos;
        var depth: usize = 1;
        while (s.pos < s.src.len and depth > 0) : (s.pos += 1) {
            switch (s.src[s.pos]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) return s.fail("unterminated block");
        return s.src[body_start .. s.pos - 1];
    }

    // The built-in gate set: each entry names the gate, its angle-parameter
    // and qubit-operand counts (which drive the one generic parse path in
    // `parseGates`), and the tag its emission switches on. `U` is the
    // stdgates alias of `u`; the lowerings (`r`, `cx`, `rzz`) live with the
    // emission, not here.
    const GateTag = enum { h, x, y, z, sx, rx, ry, rz, u, r, cz, cx, rzz };
    const Builtin = struct { name: []const u8, n_params: u8, n_qubits: u8, gate: GateTag };
    const builtins = [_]Builtin{
        .{ .name = "h", .n_params = 0, .n_qubits = 1, .gate = .h },
        .{ .name = "x", .n_params = 0, .n_qubits = 1, .gate = .x },
        .{ .name = "y", .n_params = 0, .n_qubits = 1, .gate = .y },
        .{ .name = "z", .n_params = 0, .n_qubits = 1, .gate = .z },
        .{ .name = "sx", .n_params = 0, .n_qubits = 1, .gate = .sx },
        .{ .name = "rx", .n_params = 1, .n_qubits = 1, .gate = .rx },
        .{ .name = "ry", .n_params = 1, .n_qubits = 1, .gate = .ry },
        .{ .name = "rz", .n_params = 1, .n_qubits = 1, .gate = .rz },
        .{ .name = "u", .n_params = 3, .n_qubits = 1, .gate = .u },
        .{ .name = "U", .n_params = 3, .n_qubits = 1, .gate = .u },
        .{ .name = "r", .n_params = 2, .n_qubits = 1, .gate = .r },
        .{ .name = "cz", .n_params = 0, .n_qubits = 2, .gate = .cz },
        .{ .name = "cx", .n_params = 0, .n_qubits = 2, .gate = .cx },
        .{ .name = "rzz", .n_params = 1, .n_qubits = 2, .gate = .rzz },
    };
    fn findBuiltin(word: []const u8) ?Builtin {
        for (builtins) |b| if (std.mem.eql(u8, word, b.name)) return b;
        return null;
    }

    fn parseGates(s: *QasmParser, circ: *Circuit) !void {
        while (s.pos < s.src.len) {
            s.skipWsAndComments();
            if (s.pos >= s.src.len) break;
            const stmt_start = s.pos;
            var word = s.readIdent();
            if (word.len == 0) {
                s.pos += 1;
                continue;
            }
            // `input`/`output` are declaration modifiers; the real declaration
            // keyword follows.
            if (std.mem.eql(u8, word, "input") or std.mem.eql(u8, word, "output")) {
                s.skipWs();
                word = s.readIdent();
            }

            if (std.mem.eql(u8, word, "OPENQASM") or
                std.mem.eql(u8, word, "include") or
                std.mem.eql(u8, word, "qubit"))
            {
                s.skipToSemicolon();
            } else if (std.mem.eql(u8, word, "bit")) {
                // The register was recorded in the first pass. Process an
                // initializing measurement (`bit b = measure q;`) so it is
                // validated and tracked; a plain declaration just terminates.
                s.skipWs();
                if (s.pos < s.src.len and s.src[s.pos] == '[') {
                    s.pos += 1;
                    _ = try s.readWidth();
                    try s.consume(']');
                    s.skipWs();
                }
                const name = s.readIdent();
                if (try s.assignmentMeasure(name)) |lhs| {
                    const qubits = try s.parseMeasureOperand(stmt_start);
                    if (lhs.width) |bits| {
                        if (qubits != bits)
                            return s.fail("measurement width does not match the target bit register");
                    }
                }
                s.skipToSemicolon();
            } else if (std.mem.eql(u8, word, "const") or isClassicalType(word)) {
                // A classical declaration (`const int N = 9;`, `float dt = …;`,
                // `angle theta = …;`). The value is evaluated and bound so later
                // expressions, loop bounds, and subscripts can reference it.
                try s.evalClassicalDecl(word);
            } else if (std.mem.eql(u8, word, "for")) {
                // A `for` over a static integer range unrolls into a fixed
                // sequence of gates (its bounds never depend on a measurement).
                try s.parseForLoop(circ);
            } else if (std.mem.eql(u8, word, "reset")) {
                // Reset is recorded as a front-end IR op and lowered to a
                // round-trip shuttle: the reset set repumps to |0> in the
                // readout zone, then returns to storage. A whole-register
                // reset emits one op per qubit. The operands' measured flag
                // is cleared: a reset returns them to a fresh state.
                const target = try s.parseQubitRange(
                    "expected a qubit to reset, e.g. `reset q;`",
                    "reset of an undeclared register",
                );
                try s.consume(';');
                s.unmarkMeasured(target.base, target.count);
                for (0..target.count) |k|
                    try circ.reset(target.base + @as(u32, @intCast(k)));
            } else if (findBuiltin(word)) |g| {
                // A built-in gate, `name(p0, …) q0, q1;` — the table's counts
                // drive one shared parse of the angle parameters and qubit
                // operands.
                var p: [3]f64 = undefined;
                if (g.n_params > 0) {
                    try s.consume('(');
                    for (p[0..g.n_params], 0..) |*param, i| {
                        if (i > 0) try s.consume(',');
                        param.* = try s.parseExpr();
                    }
                    try s.consume(')');
                }
                var q: [2]u32 = undefined;
                for (q[0..g.n_qubits], 0..) |*operand, i| {
                    if (i > 0) try s.consume(',');
                    operand.* = try s.parseQubitRef();
                }
                try s.consume(';');
                // A two-qubit gate on one qubit is ill-formed: the operands
                // must be distinct qubits.
                if (g.n_qubits == 2 and q[0] == q[1]) {
                    s.pos = stmt_start;
                    return s.fail("two-qubit gate on a single qubit");
                }
                switch (g.gate) {
                    .h => try circ.h(q[0]),
                    .x => try circ.x(q[0]),
                    .y => try circ.y(q[0]),
                    .z => try circ.z(q[0]),
                    .sx => try circ.sx(q[0]),
                    .rx => try circ.rx(q[0], p[0]),
                    .ry => try circ.ry(q[0], p[0]),
                    .rz => try circ.rz(q[0], p[0]),
                    .u => try circ.u(q[0], p[0], p[1], p[2]),
                    // r(θ,φ) = U(θ, -π/2+φ, π/2-φ)
                    .r => try circ.u(q[0], p[0], -PI / 2.0 + p[1], PI / 2.0 - p[1]),
                    .cz => try circ.cz(q[0], q[1]),
                    .cx => try circ.cx(q[0], q[1]),
                    .rzz => try circ.rzz(q[0], q[1], p[0]),
                }
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
                if (isGateModifier(word))
                    return s.fail("gate modifiers (ctrl, negctrl, inv, pow) are not supported");
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

    // Gate modifiers (`ctrl @`, `negctrl @`, `inv @`, `pow(k) @`). Compiling a
    // modified gate — most often a multi-controlled `ctrl(n) @ x` — into native
    // U/CZ gates needs a controlled-gate synthesis pass this compiler does not
    // have, so a modified gate is reported as unsupported rather than miscompiled.
    fn isGateModifier(word: []const u8) bool {
        const kws = [_][]const u8{ "ctrl", "negctrl", "inv", "pow" };
        for (kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
        return false;
    }

    // OpenQASM keywords this compiler recognizes but cannot compile, named so
    // the error reads as "unsupported" rather than "unrecognized" (a typo or
    // unknown gate). Dropping any of these would change the result.
    fn isUnsupportedConstruct(word: []const u8) bool {
        const kws = [_][]const u8{
            "if",
            "while",
            "defcal",
            "cal",
            "box",
            "creg",
            "qreg",
            "gate",
            "def",
            "return",
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
        return .{
            .word = w,
            .hint = "unrecognized statement; did you mean '" ++ w ++ "'?",
        };
    }
    fn suggestGate(comptime w: []const u8, comptime hint: []const u8) Suggestion {
        return .{
            .word = w,
            .hint = "unknown gate; did you mean " ++ hint ++ "?",
        };
    }
    const suggestions = [_]Suggestion{
        suggestStmt("qubit"),
        suggestStmt("bit"),
        suggestStmt("measure"),
        suggestStmt("include"),
        suggestGate("cx", "'cx' or 'cz'"),
        suggestGate("cz", "'cx' or 'cz'"),
        suggestGate("rx", "'rx', 'ry', or 'rz'"),
        suggestGate("ry", "'rx', 'ry', or 'rz'"),
        suggestGate("rz", "'rx', 'ry', or 'rz'"),
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
    const loop = "qubit[2] q;\nwhile (true) { x q[0]; }\nmeasure q;\n";
    var pr = QasmParser.init(std.testing.allocator, loop);
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

test "QasmParser accepts single-qubit declarations and bare references" {
    // `qubit q;` declares a width-1 register, referenced bare (no index).
    const src =
        \\qubit a;
        \\qubit b;
        \\h a;
        \\cx a, b;
        \\bit m = measure a;
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(2, circ.n);
    // h a -> U(a); cx a,b -> H-CZ-H on the target b.
    try std.testing.expectEqual(4, circ.gates.items.len);
    try std.testing.expectEqual(0, circ.gates.items[0].u.qubit);
    try std.testing.expectEqual(0, circ.gates.items[2].cz.control);
    try std.testing.expectEqual(1, circ.gates.items[2].cz.target);
}

test "QasmParser rejects a bare reference to a multi-qubit register" {
    const src = "qubit[2] q;\nh q;\nmeasure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("a multi-qubit register needs an index", p.reason.?);
}

test "QasmParser records reset as a front-end IR op" {
    // `reset q;` is recorded as a reset op (it precedes the `h`), not dropped.
    const src = "qubit q;\nreset q;\nh q;\nbit m = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(2, circ.gates.items.len);
    try std.testing.expectEqual(.reset, std.meta.activeTag(circ.gates.items[0]));
    try std.testing.expectEqual(0, circ.gates.items[0].reset.qubit);
    try std.testing.expectEqual(0, circ.gates.items[1].u.qubit);

    // A whole-register reset expands to one op per qubit.
    const whole = "qubit[3] q;\nreset q;\nmeasure q;\n";
    var pw = QasmParser.init(std.testing.allocator, whole);
    var cw = try pw.parse();
    defer cw.deinit();
    try std.testing.expectEqual(3, cw.gates.items.len);
    try std.testing.expectEqual(2, cw.gates.items[2].reset.qubit);

    // An out-of-range reset operand is still an error.
    const bad = "qubit[2] q;\nreset q[5];\nmeasure q;\n";
    var pb = QasmParser.init(std.testing.allocator, bad);
    try std.testing.expectError(error.ParseError, pb.parse());
    try std.testing.expectEqualStrings("qubit index out of range", pb.reason.?);
}

test "QasmParser registers an output bit and width-checks it" {
    // `output bit c;` registers c as a single bit, so measuring the 2-qubit
    // register `q` into it is a width mismatch.
    const src = "qubit[2] q;\noutput bit c;\nc = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("measurement width does not match the target bit register", p.reason.?);
}

test "QasmParser width-checks a combined bit-declaration measurement" {
    // `bit b = measure q;` measures and assigns in one statement; a 1-bit
    // target with a 2-qubit operand is a width mismatch.
    const src = "qubit[2] q;\nbit b = measure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("measurement width does not match the target bit register", p.reason.?);
}

test "QasmParser unrolls a for loop over a static range" {
    // `N` sizes the register and bounds the loop; the loop applies one gate per
    // qubit, so it unrolls to N gates.
    const src =
        \\const int N = 3;
        \\qubit[N] q;
        \\for int i in [0:N-1] {
        \\    h q[i];
        \\}
        \\measure q;
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(3, circ.n);
    try std.testing.expectEqual(3, circ.gates.items.len);
    try std.testing.expectEqual(0, circ.gates.items[0].u.qubit);
    try std.testing.expectEqual(1, circ.gates.items[1].u.qubit);
    try std.testing.expectEqual(2, circ.gates.items[2].u.qubit);
}

test "QasmParser steps a for loop range" {
    // `[0:2:N-1]` with N=5 yields 0, 2, 4.
    const src =
        \\const int N = 5;
        \\qubit[N] q;
        \\for int i in [0:2:N-1] {
        \\    h q[i];
        \\}
        \\measure q;
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(3, circ.gates.items.len);
    try std.testing.expectEqual(0, circ.gates.items[0].u.qubit);
    try std.testing.expectEqual(2, circ.gates.items[1].u.qubit);
    try std.testing.expectEqual(4, circ.gates.items[2].u.qubit);
}

test "QasmParser measures a loop-indexed qubit" {
    // The measure operand's index is a constant expression, so a loop
    // variable resolves per unrolled iteration.
    const src =
        \\qubit[3] q;
        \\bit[3] c;
        \\for int i in [0:2] {
        \\    h q[i];
        \\    measure q[i] -> c[i];
        \\}
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(3, circ.gates.items.len);
}

test "QasmParser assigns a loop-indexed measurement" {
    // Assignment form: the bit index on the target is a constant expression
    // too, bounds-checked per unrolled iteration.
    const src =
        \\qubit[2] q;
        \\bit[2] c;
        \\for int i in [0:1] {
        \\    h q[i];
        \\    c[i] = measure q[i];
        \\}
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(2, circ.gates.items.len);
}

test "QasmParser bit-index-checks a loop-indexed measurement target" {
    // The loop runs i up to 2, but c has only 2 bits, so the third
    // iteration's `c[2]` is out of range.
    const src =
        \\qubit[3] q;
        \\bit[2] c;
        \\for int i in [0:2] {
        \\    c[i] = measure q[i];
        \\}
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("bit index out of range", p.reason.?);
}

test "QasmParser lowers rzz to CX-Rz-CX" {
    const src =
        \\qubit[2] q;
        \\rzz(0.5) q[0], q[1];
        \\measure q;
    ;
    var p = QasmParser.init(std.testing.allocator, src);
    var circ = try p.parse();
    defer circ.deinit();

    // rzz -> cx; rz; cx, and each cx -> H-CZ-H: 3 + 1 + 3 = 7 gates, with the
    // rz on the target between the two CZs.
    try std.testing.expectEqual(7, circ.gates.items.len);
    try std.testing.expectEqual(.cz, std.meta.activeTag(circ.gates.items[1]));
    try std.testing.expectEqual(1, circ.gates.items[3].u.qubit);
    try std.testing.expectEqual(0.5, circ.gates.items[3].u.lambda); // rz angle
    try std.testing.expectEqual(.cz, std.meta.activeTag(circ.gates.items[5]));
}

test "QasmParser rejects an assignment to a non-classical target" {
    // `c` is a bit register, not a classical variable, so `c[0] = q;` is not a
    // modeled classical assignment and stays an error rather than being dropped.
    const src = "qubit[2] q;\nbit[2] c;\nc[0] = q;\nmeasure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("unrecognized statement", p.reason.?);
}

test "QasmParser reset clears measurement tracking" {
    var warns: std.ArrayList(Diagnostic) = .empty;
    defer warns.deinit(std.testing.allocator);

    // Measure, reset, then operate and measure again. The reset returns the
    // qubit to a fresh state, so neither the use-after-measure nor the
    // remeasure warning fires — and reset itself no longer warns.
    const src = "qubit[1] q;\nbit[1] c;\nmeasure q -> c;\nreset q;\nh q;\nmeasure q -> c;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    p.warn_sink = &warns;
    var circ = try p.parse();
    defer circ.deinit();

    try std.testing.expectEqual(0, warns.items.len);
}

test "QasmParser reports a gate modifier as unsupported" {
    const src = "qubit[3] q;\nctrl(2) @ x q[0], q[1], q[2];\nmeasure q;\n";
    var p = QasmParser.init(std.testing.allocator, src);
    try std.testing.expectError(error.ParseError, p.parse());
    try std.testing.expectEqualStrings("gate modifiers (ctrl, negctrl, inv, pow) are not supported", p.reason.?);
}

test {
    std.testing.refAllDecls(@This());
}
