//! JSON serialization for compiler outputs. All output formats live here so
//! the contract with downstream consumers is reviewable in one place.

const std = @import("std");
const schedule = @import("schedule");
const bench = @import("bench");

/// Serializes a logical schedule (SLM slot assignment plus per-timeframe AOD
/// slot rows) to an owned JSON string. Takes the slot tables directly rather
/// than route.Sequence so this module never depends on route (route's tests
/// file-import this module via snapshot.zig).
pub fn sequenceToJson(
    gpa: std.mem.Allocator,
    fixed: []const ?usize,
    moveable: []const []?usize,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");

    try w.writeAll("  \"slm_slots\": [");
    for (fixed, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
    }
    try w.writeAll("],\n");

    try w.writeAll("  \"aod_slots_per_color\": [\n");
    for (moveable, 0..) |row, ci| {
        try w.writeAll("    [");
        for (row, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
        }
        const last = ci == moveable.len - 1;
        try w.writeAll(if (last) "]\n" else "],\n");
    }
    try w.writeAll("  ],\n");

    try w.print("  \"max_color\": {d}\n", .{@as(i32, @intCast(moveable.len)) - 1});
    try w.writeAll("}");

    return gpa.dupe(u8, buf.written());
}

/// Serializes a hardware schedule (per-qubit load/move/store/raman/rydberg/
/// measure ops, grouped by timestep) to an owned JSON string.
pub fn hardwareToJson(gpa: std.mem.Allocator, hw: *const schedule.Hardware) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");
    try w.writeAll("  \"version\": \"1.1\",\n");
    try w.writeAll("  \"platform\": \"taiyi-v1\",\n");
    try w.print("  \"num_qubits\": {d},\n", .{hw.placement.len});
    try w.writeAll("  \"ops\": [\n");

    var total: usize = 0;
    for (hw.frames.items) |frame| total += frame.items.len;

    var i: usize = 0;
    for (hw.frames.items, 0..) |frame, t| {
        for (frame.items) |op| {
            defer i += 1;
            const last_op = i == total - 1;
            try w.writeAll("    {\n");
            switch (op) {
                .raman => |r| {
                    try w.writeAll("      \"op\": \"raman\",\n");
                    try w.print("      \"angle\": {d:.4},\n", .{r.angle});
                    try w.print("      \"phase\": {d:.4},\n", .{r.phase});
                    try w.print("      \"t\": {d},\n", .{t});
                    try w.writeAll("      \"targets\": [\n");
                    for (r.targets, 0..) |target, j| {
                        const last = j == r.targets.len - 1;
                        try w.print("        {{ \"qubit\": {d}, \"x\": {d}, \"y\": {d} }}", .{
                            target.qubit,
                            target.pos.x,
                            target.pos.y,
                        });
                        try w.writeAll(if (last) "\n" else ",\n");
                    }
                    try w.writeAll("      ]\n");
                },
                .move => |m| {
                    try w.writeAll("      \"op\": \"move\",\n");
                    try w.print("      \"qubit\": {d},\n", .{m.qubit});
                    try w.print("      \"from\": {{ \"x\": {d}, \"y\": {d} }},\n", .{ m.src.x, m.src.y });
                    try w.print("      \"to\": {{ \"x\": {d}, \"y\": {d} }},\n", .{ m.dest.x, m.dest.y });
                    try w.print("      \"t\": {d}\n", .{t});
                },
                .rydberg => |r| {
                    try w.writeAll("      \"op\": \"rydberg\",\n");
                    try w.print("      \"zone\": \"{s}\",\n", .{zoneName(r.zone)});
                    try w.print("      \"t\": {d}\n", .{t});
                },
                .measure => |m| {
                    try w.writeAll("      \"op\": \"measure\",\n");
                    try w.print("      \"zone\": \"{s}\",\n", .{zoneName(m.zone)});
                    try w.writeAll("      \"basis\": \"Z\",\n");
                    try w.print("      \"t\": {d},\n", .{t});
                    try w.writeAll("      \"qubits\": [");
                    for (m.qubits, 0..) |q, j| {
                        if (j > 0) try w.writeAll(", ");
                        try w.print("{d}", .{q});
                    }
                    try w.writeAll("]\n");
                },
                .load => |ld| {
                    try w.writeAll("      \"op\": \"load\",\n");
                    try w.print("      \"qubit\": {d},\n", .{ld.qubit});
                    try w.print("      \"x\": {d},\n", .{ld.position.x});
                    try w.print("      \"y\": {d},\n", .{ld.position.y});
                    try w.print("      \"t\": {d}\n", .{t});
                },
                .store => |st| {
                    try w.writeAll("      \"op\": \"store\",\n");
                    try w.print("      \"qubit\": {d},\n", .{st.qubit});
                    try w.print("      \"x\": {d},\n", .{st.position.x});
                    try w.print("      \"y\": {d},\n", .{st.position.y});
                    try w.print("      \"t\": {d}\n", .{t});
                },
            }
            try w.writeAll(if (last_op) "    }\n" else "    },\n");
        }
    }

    try w.writeAll("  ]\n");
    try w.writeAll("}");

    return gpa.dupe(u8, buf.written());
}

/// Serializes benchmark metrics (timing model, op counts, routing overhead,
/// parallelism) for one compiled schedule to an owned JSON string. One object
/// per circuit; a benchmarking driver collects these across the circuit suite.
pub fn benchToJson(gpa: std.mem.Allocator, m: bench.Metrics) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");
    try w.print("  \"num_qubits\": {d},\n", .{m.num_qubits});
    try w.print("  \"frames\": {d},\n", .{m.frames});

    try w.print(
        "  \"ops\": {{ \"load\": {d}, \"store\": {d}, \"move\": {d}, \"rydberg\": {d}, \"raman\": {d}, \"measure\": {d} }},\n",
        .{ m.n_load, m.n_store, m.n_move, m.n_rydberg, m.n_raman, m.n_measure },
    );
    try w.print(
        "  \"entangling\": {{ \"pulses\": {d}, \"cz_pairs\": {d}, \"avg_cz_per_pulse\": {d:.3} }},\n",
        .{ m.n_rydberg, m.cz_pairs, m.avgCzPerPulse() },
    );
    try w.print(
        "  \"distance_nm\": {{ \"total\": {d:.1}, \"max\": {d:.1} }},\n",
        .{ m.total_move_nm, m.max_move_nm },
    );

    try w.writeAll("  \"time_us\": {\n");
    try w.print("    \"loading\": {d:.3},\n", .{m.loading_us});
    try w.print("    \"shuttling\": {d:.3},\n", .{m.shuttling_us});
    try w.print("    \"routing\": {d:.3},\n", .{m.routingUs()});
    try w.print("    \"gate\": {d:.3},\n", .{m.gateUs()});
    try w.print("    \"total\": {d:.3}\n", .{m.totalUs()});
    try w.writeAll("  },\n");

    try w.writeAll("  \"timing_model\": {\n");
    try w.print("    \"shuttle_nm_per_us\": {d:.3},\n", .{m.timing.shuttle_nm_per_us});
    try w.print("    \"load_us\": {d:.3},\n", .{m.timing.load_us});
    try w.print("    \"store_us\": {d:.3},\n", .{m.timing.store_us});
    try w.print("    \"rydberg_us\": {d:.3},\n", .{m.timing.rydberg_us});
    try w.print("    \"raman_us\": {d:.3}\n", .{m.timing.raman_us});
    try w.writeAll("  },\n");

    if (m.compile_ns) |ns|
        try w.print("  \"compile_ns\": {d}\n", .{ns})
    else
        try w.writeAll("  \"compile_ns\": null\n");

    try w.writeAll("}");

    return gpa.dupe(u8, buf.written());
}

pub fn writeJsonFile(io: std.Io, filename: []const u8, json: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    try file.writePositionalAll(io, json, 0);
}

pub fn writeSequence(
    gpa: std.mem.Allocator,
    io: std.Io,
    filename: []const u8,
    fixed: []const ?usize,
    moveable: []const []?usize,
) !void {
    const json = try sequenceToJson(gpa, fixed, moveable);
    defer gpa.free(json);
    try writeJsonFile(io, filename, json);
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

test {
    std.testing.refAllDecls(@This());
}
