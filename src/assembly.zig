//! Loader for the storage-zone occupancy handoff from the upstream
//! atom-rearrangement (Atom Assembly) package — see example/assembly.json.
//!
//! The file carries a rows x cols 0/1 matrix over the storage SLM trap grid:
//! occupancy[row][col] == 1 means an atom sits at trap (grid.x(col),
//! grid.y(row)). Qubit ids are assigned by scanning the highest row index
//! (compute-facing) first, columns left to right — the same order the
//! procedural placement in schedule.Hardware.init uses.
const std = @import("std");
const schedule = @import("schedule");

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
    const doc = try std.mem.replaceOwned(u8, std.testing.allocator, test_doc, "\"num_atoms\": 3", "\"num_atoms\": 4");
    defer std.testing.allocator.free(doc);
    try std.testing.expectError(error.AtomCountMismatch, parse(std.testing.allocator, doc));
}

test "parse rejects an occupancy matrix that disagrees with rows/cols" {
    const doc = try std.mem.replaceOwned(u8, std.testing.allocator, test_doc, "\"cols\": 4", "\"cols\": 5");
    defer std.testing.allocator.free(doc);
    try std.testing.expectError(error.MalformedOccupancy, parse(std.testing.allocator, doc));
}

test "parse rejects occupancy cells other than 0 and 1" {
    const doc = try std.mem.replaceOwned(u8, std.testing.allocator, test_doc, "[0,1,1,0]", "[0,2,1,0]");
    defer std.testing.allocator.free(doc);
    try std.testing.expectError(error.Overflow, parse(std.testing.allocator, doc));
}

test "the example assembly file loads" {
    const a = try load(std.testing.allocator, std.testing.io, "example/assembly.json");
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 10), a.rows);
    try std.testing.expectEqual(@as(u32, 110), a.cols);
    try std.testing.expectEqual(@as(usize, 16), a.sites.len);
    // 4x4 block: first qubit sits in the compute-facing row at the block's left edge.
    try std.testing.expectEqual(schedule.Site{ .row = 9, .col = 53 }, a.sites[0]);
}

test {
    @import("testutil").refAllDeclsRecursive(@This());
}
