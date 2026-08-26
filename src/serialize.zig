//! JSON serialization for compiler outputs. All output formats live here so
//! the contract with downstream consumers is reviewable in one place.

const std = @import("std");
const arch = @import("arch");
const schedule = @import("schedule");
const bench = @import("bench");

fn field(s: *std.json.Stringify, name: []const u8, v: anytype) !void {
    try s.objectField(name);
    try s.write(v);
}

fn fieldFmt(s: *std.json.Stringify, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try s.objectField(name);
    try s.print(fmt, args);
}

fn writeSlotRow(s: *std.json.Stringify, row: []const ?usize) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll("[");
    for (row, 0..) |v, i| {
        if (i > 0) try s.writer.writeAll(", ");
        if (v) |slot| try s.writer.print("{d}", .{slot}) else try s.writer.writeAll("null");
    }
    try s.writer.writeAll("]");
    s.endWriteRaw();
}

pub fn sequenceToJson(
    gpa: std.mem.Allocator,
    fixed: []const ?usize,
    moveable: []const []?usize,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    var s: std.json.Stringify = .{
        .writer = &buf.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try s.beginObject();
    try s.objectField("slm_slots");
    try writeSlotRow(&s, fixed);
    try s.objectField("aod_slots_per_color");
    try s.beginArray();
    for (moveable) |row| try writeSlotRow(&s, row);
    try s.endArray();
    try field(&s, "max_color", @as(i32, @intCast(moveable.len)) - 1);
    try s.endObject();

    return gpa.dupe(u8, buf.written());
}

pub fn hardwareToJson(gpa: std.mem.Allocator, hw: *const schedule.Hardware) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    var s: std.json.Stringify = .{
        .writer = &buf.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try s.beginObject();
    try field(&s, "version", hw.cfg.platform.version);
    try field(&s, "platform", hw.cfg.platform.name);
    try field(&s, "num_qubits", hw.placement.len);
    try s.objectField("ops");
    try s.beginArray();

    var run: std.ArrayList(schedule.Move) = .empty;
    defer run.deinit(gpa);

    for (hw.frames.items, 0..) |frame, t| {
        var axis: Axis = .none;

        for (frame.items) |op| switch (op) {
            .move => |m| {
                const a: Axis = if (m.dest.x != m.src.x) .x else if (m.dest.y != m.src.y) .y else .none;

                if (a != .none and axis != .none and a != axis) {
                    try writeMoveRun(&s, hw.cfg, axis, run.items, t);
                    run.clearRetainingCapacity();
                    axis = .none;
                }

                if (axis == .none) axis = a;

                try run.append(gpa, m);
            },
            else => {
                if (run.items.len > 0) {
                    try writeMoveRun(&s, hw.cfg, axis, run.items, t);
                    run.clearRetainingCapacity();
                    axis = .none;
                }

                try writeOp(&s, op, t);
            },
        };

        if (run.items.len > 0) {
            try writeMoveRun(&s, hw.cfg, axis, run.items, t);
            run.clearRetainingCapacity();
        }
    }

    try s.endArray();
    try s.endObject();

    return gpa.dupe(u8, buf.written());
}

const Axis = enum { none, x, y };

/// One AOD translation: all moves in a frame that share a direction, emitted
/// as a single grouped op. Runs are split on axis changes and on interleaved
/// non-move ops, so array order within a timestep is preserved.
fn writeMoveRun(
    s: *std.json.Stringify,
    cfg: arch.ArchConfig,
    axis: Axis,
    moves: []const schedule.Move,
    t: usize,
) !void {
    try s.beginObject();
    try field(s, "op", "move");
    try field(s, "aod", cfg.aod.aod_id);
    try field(s, "translate", if (axis == .y) "y" else "x");
    try field(s, "from_zone", zoneBandName(cfg, moves[0].src.y));
    try field(s, "to_zone", zoneBandName(cfg, moves[0].dest.y));
    try field(s, "t", t);
    try s.objectField("atoms");
    try s.beginArray();
    for (moves) |m| {
        try s.print(
            "{{ \"qubit\": {d}, \"from\": {{ \"x\": {d}, \"y\": {d} }}, \"to\": {{ \"x\": {d}, \"y\": {d} }} }}",
            .{ m.qubit, m.src.x, m.src.y, m.dest.x, m.dest.y },
        );
    }
    try s.endArray();
    try s.endObject();
}

fn zoneBandName(cfg: arch.ArchConfig, y: i32) []const u8 {
    if (inBand(cfg.storage_zone.box(), y)) return zoneName(.storage);
    if (inBand(cfg.compute_zone.box(), y)) return zoneName(.compute);
    if (inBand(cfg.readout_zone.box(), y)) return zoneName(.readout);
    return "transit";
}

fn inBand(b: arch.ZoneBox, y: i32) bool {
    return y >= b.min[1] and y <= b.max[1];
}

fn writeOp(s: *std.json.Stringify, op: schedule.OpKind, t: usize) !void {
    try s.beginObject();
    try field(s, "op", @tagName(op));

    switch (op) {
        .raman => |r| {
            try fieldFmt(s, "angle", "{d:.4}", .{r.angle});
            try fieldFmt(s, "phase", "{d:.4}", .{r.phase});
            try field(s, "t", t);
            try s.objectField("targets");
            try s.beginArray();
            for (r.targets) |target| {
                try s.print("{{ \"qubit\": {d}, \"x\": {d}, \"y\": {d} }}", .{
                    target.qubit, target.pos.x, target.pos.y,
                });
            }
            try s.endArray();
        },
        // Moves never reach writeOp: hardwareToJson groups them into
        // per-AOD runs and emits them via writeMoveRun.
        .move => unreachable,
        .rydberg => |r| {
            try field(s, "zone", zoneName(r.zone));
            try field(s, "t", t);
        },
        .measure => |m| {
            try field(s, "zone", zoneName(m.zone));
            try field(s, "basis", "Z");
            try field(s, "t", t);
            try s.objectField("qubits");
            try s.beginWriteRaw();
            try s.writer.writeAll("[");
            for (m.qubits, 0..) |q, i| {
                if (i > 0) try s.writer.writeAll(", ");
                try s.writer.print("{d}", .{q});
            }
            try s.writer.writeAll("]");
            s.endWriteRaw();
        },
        .reset => |r| {
            try field(s, "zone", zoneName(r.zone));
            try field(s, "t", t);
            try s.objectField("qubits");
            try s.beginWriteRaw();
            try s.writer.writeAll("[");
            for (r.qubits, 0..) |q, i| {
                if (i > 0) try s.writer.writeAll(", ");
                try s.writer.print("{d}", .{q});
            }
            try s.writer.writeAll("]");
            s.endWriteRaw();
        },
        .load => |ld| {
            try field(s, "qubit", ld.qubit);
            try field(s, "x", ld.position.x);
            try field(s, "y", ld.position.y);
            try field(s, "t", t);
        },
        .store => |st| {
            try field(s, "qubit", st.qubit);
            try field(s, "x", st.position.x);
            try field(s, "y", st.position.y);
            try field(s, "t", t);
        },
    }

    try s.endObject();
}

pub fn benchToJson(gpa: std.mem.Allocator, m: bench.Metrics) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    var s: std.json.Stringify = .{
        .writer = &buf.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try s.beginObject();
    try field(&s, "num_qubits", m.num_qubits);
    try field(&s, "frames", m.frames);
    try fieldFmt(
        &s,
        "ops",
        "{{ \"load\": {d}, \"store\": {d}, \"move\": {d}, \"rydberg\": {d}, \"raman\": {d}, \"measure\": {d}, \"reset\": {d} }}",
        .{ m.n_load, m.n_store, m.n_move, m.n_rydberg, m.n_raman, m.n_measure, m.n_reset },
    );
    try fieldFmt(
        &s,
        "entangling",
        "{{ \"pulses\": {d}, \"cz_pairs\": {d}, \"avg_cz_per_pulse\": {d:.3} }}",
        .{ m.n_rydberg, m.cz_pairs, m.avgCzPerPulse() },
    );
    try fieldFmt(
        &s,
        "distance_nm",
        "{{ \"total\": {d:.1}, \"max\": {d:.1} }}",
        .{ m.total_move_nm, m.max_move_nm },
    );

    try s.objectField("time_us");
    try s.beginObject();
    try fieldFmt(&s, "loading", "{d:.3}", .{m.loading_us});
    try fieldFmt(&s, "shuttling", "{d:.3}", .{m.shuttling_us});
    try fieldFmt(&s, "routing", "{d:.3}", .{m.routingUs()});
    try fieldFmt(&s, "gate", "{d:.3}", .{m.gateUs()});
    try fieldFmt(&s, "total", "{d:.3}", .{m.totalUs()});
    try s.endObject();

    try s.objectField("timing_model");
    try s.beginObject();
    try fieldFmt(&s, "shuttle_nm_per_us", "{d:.3}", .{bench.Timing.shuttle_nm_per_us});
    try fieldFmt(&s, "load_us", "{d:.3}", .{bench.Timing.load_us});
    try fieldFmt(&s, "store_us", "{d:.3}", .{bench.Timing.store_us});
    try fieldFmt(&s, "rydberg_us", "{d:.3}", .{bench.Timing.rydberg_us});
    try fieldFmt(&s, "raman_us", "{d:.3}", .{bench.Timing.raman_us});
    try fieldFmt(&s, "reset_us", "{d:.3}", .{bench.Timing.reset_us});
    try s.endObject();

    try field(&s, "compile_ns", m.compile_ns);
    try s.endObject();

    return gpa.dupe(u8, buf.written());
}

pub fn writeJsonFile(io: std.Io, filename: []const u8, json: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    try file.writePositionalAll(io, json, 0);
}

pub fn writeHardware(
    gpa: std.mem.Allocator,
    io: std.Io,
    filename: []const u8,
    hw: *const schedule.Hardware,
) !void {
    const json = try hardwareToJson(gpa, hw);
    defer gpa.free(json);
    try writeJsonFile(io, filename, json);
}

pub fn writeBench(
    gpa: std.mem.Allocator,
    io: std.Io,
    filename: []const u8,
    m: bench.Metrics,
) !void {
    const json = try benchToJson(gpa, m);
    defer gpa.free(json);
    try writeJsonFile(io, filename, json);
}

fn zoneName(z: schedule.Zone) []const u8 {
    return switch (z) {
        .storage => "storage",
        .compute => "compute",
        .readout => "readout_zone",
    };
}

/// Test helper: byte-compares `actual` against the checked-in snapshot at
/// `path`, printing a diff-style report on mismatch and a regeneration hint
/// when the snapshot is missing. Lives here because every snapshot producer
/// (route's graph snapshots, golden's pipeline snapshots) already imports
/// this module.
pub fn expectMatchesFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    actual: []const u8,
) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                "\nSnapshot missing: {s}\n" ++
                    "  Run `zig build update-snapshots` to generate it.\n",
                .{path},
            );
        }
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const expected = try gpa.alloc(u8, stat.size);
    defer gpa.free(expected);
    _ = try file.readPositionalAll(io, expected, 0);

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print(
            "\nSnapshot mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
            .{ path, expected, actual },
        );
        return error.SnapshotMismatch;
    }
}

test {
    std.testing.refAllDecls(@This());
}
