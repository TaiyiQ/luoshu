//! Loader for the storage-zone occupancy handoff from the upstream
//! atom-rearrangement (Atom Assembly) package — see cfg/assembly.json.
//!
//! The file carries a rows x cols 0/1 matrix over the storage SLM trap grid:
//! occupancy[row][col] == 1 means an atom sits at trap (grid.x(col),
//! grid.y(row)). Qubit ids are assigned by scanning the highest row index
//! (compute-facing) first, columns left to right — the same order the
//! procedural placement in schedule.Hardware.init uses.

const std = @import("std");
const arch = @import("arch");
const schedule = @import("schedule");
const trace = @import("trace");

pub const AssemblyError = error{
    MalformedOccupancy,
    AtomCountMismatch,
};

/// Mirrors the JSON exactly; `metadata` and other upstream-only fields
/// are ignored. Occupancy cells are u1 so anything but 0/1 fails parsing.
const Raw = struct {
    schema_version: []const u8,
    platform: []const u8,
    zone_id: u32,
    slm_id: u32,
    rows: u32,
    cols: u32,
    num_atoms: u32,
    occupancy: []const []const u1,
};

pub const Assembly = struct {
    zone_id: u32,
    slm_id: u32,
    rows: u32,
    cols: u32,
    /// Occupied traps in qubit-id order.
    sites: []schedule.Site,

    pub fn deinit(s: Assembly, gpa: std.mem.Allocator) void {
        gpa.free(s.sites);
    }
};

/// Parses an assembly JSON document. Caller owns the result.
pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Assembly {
    const parsed = try std.json.parseFromSlice(Raw, gpa, src, .{
        .ignore_unknown_fields = true,
    });

    defer parsed.deinit();
    const raw = parsed.value;

    if (raw.occupancy.len != raw.rows) return error.MalformedOccupancy;
    for (raw.occupancy) |row| {
        if (row.len != raw.cols) return error.MalformedOccupancy;
    }

    var sites: std.ArrayList(schedule.Site) = .empty;
    defer sites.deinit(gpa);

    var row = raw.rows;
    while (row > 0) {
        row -= 1;
        for (raw.occupancy[row], 0..) |occ, col| {
            if (occ == 1) try sites.append(gpa, .{ .row = row, .col = @intCast(col) });
        }
    }
    if (sites.items.len != raw.num_atoms) return error.AtomCountMismatch;

    return .{
        .zone_id = raw.zone_id,
        .slm_id = raw.slm_id,
        .rows = raw.rows,
        .cols = raw.cols,
        .sites = try sites.toOwnedSlice(gpa),
    };
}

/// Loads an assembly handoff from a JSON file. Caller owns the result.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Assembly {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    const reader = &fr.interface;

    const src = try reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(src);

    return parse(gpa, src);
}

pub const CheckError = error{
    StorageSlmMismatch,
    NotEnoughAtoms,
};

/// Test hook: suppresses check's diagnostic prints.
pub var quiet = false;

fn cfail(comptime fmt: []const u8, args: anytype) void {
    trace.diag(quiet, "assembly: " ++ fmt, args);
}

/// Driver-level validation, here rather than in main so it is testable:
/// the handoff must address the storage SLM exactly as the arch defines it
/// (otherwise its (row, col) indices mean different trap coordinates), and
/// must deliver at least as many atoms as the circuit needs qubits.
/// Prints a diagnostic and returns an error; the driver turns it fatal.
pub fn check(a: Assembly, cfg: arch.ArchConfig, num_qubits: usize) CheckError!void {
    const slm = cfg.storage_zone.slm;
    if (a.zone_id != cfg.storage_zone.zone_id or
        a.slm_id != slm.slm_id or
        a.rows != slm.num_row or
        a.cols != slm.num_col)
    {
        cfail("handoff (zone {d}, slm {d}, {d}x{d}) does not match the storage SLM (zone {d}, slm {d}, {d}x{d})", .{
            a.zone_id,
            a.slm_id,
            a.rows,
            a.cols,
            cfg.storage_zone.zone_id,
            slm.slm_id,
            slm.num_row,
            slm.num_col,
        });
        return error.StorageSlmMismatch;
    }
    if (num_qubits > a.sites.len) {
        cfail("circuit needs {d} qubits but the handoff delivers only {d} atoms", .{
            num_qubits, a.sites.len,
        });
        return error.NotEnoughAtoms;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const test_doc =
    \\{
    \\  "schema_version": "1.1",
    \\  "platform": "SLM",
    \\  "zone_id": 0,
    \\  "slm_id": 0,
    \\  "rows": 3,
    \\  "cols": 4,
    \\  "num_atoms": 3,
    \\  "occupancy": [
    \\    [0,0,0,0],
    \\    [0,1,0,0],
    \\    [0,1,1,0]
    \\  ],
    \\  "metadata": { "frame_id": 42, "snr": 4.48 }
    \\}
;

test "parse orders sites compute-facing row first, columns left to right" {
    const a = try parse(std.testing.allocator, test_doc);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), a.rows);
    try std.testing.expectEqual(@as(u32, 4), a.cols);
    try std.testing.expectEqualSlices(schedule.Site, &.{
        .{ .row = 2, .col = 1 },
        .{ .row = 2, .col = 2 },
        .{ .row = 1, .col = 1 },
    }, a.sites);
}

test "parse rejects an atom count that disagrees with the occupancy" {
    const doc = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        test_doc,
        "\"num_atoms\": 3",
        "\"num_atoms\": 4",
    );
    defer std.testing.allocator.free(doc);
    try std.testing.expectError(
        error.AtomCountMismatch,
        parse(std.testing.allocator, doc),
    );
}

test "parse rejects an occupancy matrix that disagrees with rows/cols" {
    const doc = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        test_doc,
        "\"cols\": 4",
        "\"cols\": 5",
    );
    defer std.testing.allocator.free(doc);
    try std.testing.expectError(
        error.MalformedOccupancy,
        parse(std.testing.allocator, doc),
    );
}

test "parse rejects occupancy cells other than 0 and 1" {
    const doc = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        test_doc,
        "[0,1,1,0]",
        "[0,2,1,0]",
    );
    defer std.testing.allocator.free(doc);
    try std.testing.expectError(
        error.Overflow,
        parse(std.testing.allocator, doc),
    );
}

test "the example assembly file loads" {
    const a = try load(
        std.testing.allocator,
        std.testing.io,
        "testdata/assembly.json",
    );
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 10), a.rows);
    try std.testing.expectEqual(@as(u32, 110), a.cols);
    try std.testing.expectEqual(@as(usize, 50), a.sites.len);
    // Fully occupied grid: the first qubit sits in the highest row index
    // (compute-facing) at the left edge.
    try std.testing.expectEqual(
        schedule.Site{ .row = 6, .col = 50 },
        a.sites[0],
    );
}

// Storage SLM congruent with test_doc: zone 0, slm 0, 3x4.
fn testCfg() arch.ArchConfig {
    var cfg = arch.testConfig();
    cfg.aod = .{ .aod_id = 0, .min_sep_nm = 0, .max_num_row = 1, .max_num_col = 1 };
    cfg.storage_zone.slm.num_row = 3;
    cfg.compute_zone.offset_nm = .{ 0, 6000 };
    cfg.compute_zone.dr_nm = 500;
    cfg.compute_zone.dw_nm = 2500;
    cfg.compute_zone.slms = &arch.test_no_slms;
    cfg.readout_zone.offset_nm = .{ 0, 12000 };
    cfg.readout_zone.slm = .{
        .slm_id = 3,
        .num_row = 1,
        .num_col = 4,
        .sep_nm = .{ 1000, 1000 },
        .offset_nm = .{ 0, 0 },
    };
    cfg.constraints.db_nm = 1000;
    cfg.constraints.dz_nm = 1000;
    return cfg;
}

test "check accepts a handoff matching the storage SLM" {
    const a = try parse(std.testing.allocator, test_doc);
    defer a.deinit(std.testing.allocator);
    try check(a, testCfg(), 3);
}

test "check rejects a handoff that mismatches the storage SLM" {
    const a = try parse(std.testing.allocator, test_doc);
    defer a.deinit(std.testing.allocator);

    var cfg = testCfg();
    cfg.storage_zone.slm.num_col = 5;

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(
        error.StorageSlmMismatch,
        check(a, cfg, 3),
    );
}

test "check rejects a circuit needing more qubits than delivered atoms" {
    const a = try parse(std.testing.allocator, test_doc);
    defer a.deinit(std.testing.allocator);

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(
        error.NotEnoughAtoms,
        check(a, testCfg(), 4),
    );
}

test {
    std.testing.refAllDecls(@This());
}
