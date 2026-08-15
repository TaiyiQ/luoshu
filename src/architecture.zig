const std = @import("std");
const toml = @import("toml");
const trace = @import("trace");

// ── Raw structs (floats) — mirrors the TOML exactly ──────────────────────────

const RawSlm = struct {
    slm_id: u32,
    num_row: u32,
    num_col: u32,
    sep_um: [2]f64,
    offset_um: [2]f64,
};

const RawStorageZone = struct {
    zone_id: u32,
    offset_um: [2]f64,
    slm: RawSlm,
};

const RawComputeZone = struct {
    zone_id: u32,
    gap_um: f64,
    dr_um: f64,
    dw_um: f64,
    slms: []RawSlm,
};

const RawReadoutZone = struct {
    zone_id: u32,
    gap_um: f64,
    slm: RawSlm,
};

const RawAod = struct {
    aod_id: u32,
    min_sep_um: f64,
    max_num_row: u32,
    max_num_col: u32,
};

const RawConstraints = struct {
    db_um: f64,
    dz_um: f64,
};

const RawArchConfig = struct {
    platform: Platform,
    aod: RawAod,
    storage_zone: RawStorageZone,
    compute_zone: RawComputeZone,
    readout_zone: RawReadoutZone,
    constraints: RawConstraints,
};

// ── Final structs (integers, nm) — used by the rest of the compiler ──────────

pub const Platform = struct {
    name: []const u8,
    version: []const u8,
};

pub const Slm = struct {
    slm_id: u32,
    num_row: u32,
    num_col: u32,
    sep_nm: [2]u32,
    offset_nm: [2]i32,
};

pub const HardwareAod = struct {
    aod_id: u32,
    min_sep_nm: u32,
    max_num_row: u32,
    max_num_col: u32,
};

/// Absolute-coordinate view of an SLM trap grid: zone offset and SLM offset
/// folded into a single origin, separations as signed nm.
pub const Grid = struct {
    origin_nm: [2]i32,
    sep_nm: [2]i32,
    num_row: u32,
    num_col: u32,

    /// Absolute x of trap column `col`.
    pub fn x(g: Grid, col: usize) i32 {
        return g.origin_nm[0] + @as(i32, @intCast(col)) * g.sep_nm[0];
    }

    /// Absolute y of trap row `row`.
    pub fn y(g: Grid, row: usize) i32 {
        return g.origin_nm[1] + @as(i32, @intCast(row)) * g.sep_nm[1];
    }

    /// Half the column separation — clearance offset that places an atom in
    /// the trap-free lane between columns.
    pub fn halfSepX(g: Grid) i32 {
        return @divTrunc(g.sep_nm[0], 2);
    }

    /// Absolute y of the last (bottom) trap row.
    pub fn bottomRowY(g: Grid) i32 {
        return g.y(g.num_row - 1);
    }
};

/// A zone's extent in absolute nm: the union of its SLM trap grids, each
/// padded by half a trap separation per side. The compiler's proxy for the
/// zone's illuminated footprint — derived from the traps rather than
/// configured, so it can never drift from the grid geometry.
pub const ZoneBox = struct {
    min: [2]i32,
    max: [2]i32,

    fn fromGrid(g: Grid) ZoneBox {
        const hx = g.halfSepX();
        const hy = @divTrunc(g.sep_nm[1], 2);
        return .{
            .min = .{ g.x(0) - hx, g.y(0) - hy },
            .max = .{ g.x(g.num_col - 1) + hx, g.y(g.num_row - 1) + hy },
        };
    }

    fn join(a: ZoneBox, b: ZoneBox) ZoneBox {
        return .{
            .min = .{ @min(a.min[0], b.min[0]), @min(a.min[1], b.min[1]) },
            .max = .{ @max(a.max[0], b.max[0]), @max(a.max[1], b.max[1]) },
        };
    }
};

fn slmGrid(zone_offset_nm: [2]i32, slm: Slm) Grid {
    return .{
        .origin_nm = .{
            zone_offset_nm[0] + slm.offset_nm[0],
            zone_offset_nm[1] + slm.offset_nm[1],
        },
        .sep_nm = .{
            @intCast(slm.sep_nm[0]),
            @intCast(slm.sep_nm[1]),
        },
        .num_row = slm.num_row,
        .num_col = slm.num_col,
    };
}

pub const StorageZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    slm: Slm,

    pub fn grid(z: StorageZone) Grid {
        return slmGrid(z.offset_nm, z.slm);
    }

    pub fn box(z: StorageZone) ZoneBox {
        return .fromGrid(z.grid());
    }
};

pub const ComputeZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    dr_nm: u32,
    dw_nm: u32,
    slms: []Slm,

    pub fn grid(z: ComputeZone, slm_idx: usize) Grid {
        return slmGrid(z.offset_nm, z.slms[slm_idx]);
    }

    pub fn box(z: ComputeZone) ZoneBox {
        if (z.slms.len == 0) return .{ .min = z.offset_nm, .max = z.offset_nm };
        var b = ZoneBox.fromGrid(z.grid(0));
        for (1..z.slms.len) |i| b = b.join(.fromGrid(z.grid(i)));
        return b;
    }
};

pub const ReadoutZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    slm: Slm,

    pub fn grid(z: ReadoutZone) Grid {
        return slmGrid(z.offset_nm, z.slm);
    }

    pub fn box(z: ReadoutZone) ZoneBox {
        return .fromGrid(z.grid());
    }
};

pub const Constraints = struct {
    db_nm: u32,
    dz_nm: u32,
};

pub const ArchConfig = struct {
    platform: Platform,
    aod: HardwareAod,
    storage_zone: StorageZone,
    compute_zone: ComputeZone,
    readout_zone: ReadoutZone,
    constraints: Constraints,

    /// Trap-free y lane between the storage and compute zones: half the
    /// inter-zone gap above the compute zone's top SLM row, with half-sep
    /// clearance from the trap sites. Safe for x alignment moves.
    pub fn corridorY(s: ArchConfig) i32 {
        const cg = s.compute_zone.grid(0);
        const gap = @divTrunc(cg.y(0) - s.storage_zone.grid().bottomRowY(), 2);
        return cg.y(0) - cg.halfSepX() - gap;
    }

    pub fn deinit(self: ArchConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.platform.name);
        allocator.free(self.platform.version);
        allocator.free(self.compute_zone.slms);
    }

    pub fn print(s: ArchConfig) void {
        std.debug.print(">> ArchConfig\n", .{});
        std.debug.print("  Platform:     {s} v{s}\n", .{
            s.platform.name,
            s.platform.version,
        });
        std.debug.print("  AOD:          id={d}  rows={d}  cols={d}  min_sep={d}nm\n", .{
            s.aod.aod_id,
            s.aod.max_num_row,
            s.aod.max_num_col,
            s.aod.min_sep_nm,
        });
        std.debug.print("  Storage:      zone={d}  slm={d}  {d}x{d} traps  sep=({d},{d})nm\n", .{
            s.storage_zone.zone_id,
            s.storage_zone.slm.slm_id,
            s.storage_zone.slm.num_row,
            s.storage_zone.slm.num_col,
            s.storage_zone.slm.sep_nm[0],
            s.storage_zone.slm.sep_nm[1],
        });
        std.debug.print("  Compute zone: zone={d}  dr={d}nm  dw={d}nm  slms={d}\n", .{
            s.compute_zone.zone_id,
            s.compute_zone.dr_nm,
            s.compute_zone.dw_nm,
            s.compute_zone.slms.len,
        });
        for (s.compute_zone.slms) |slm| {
            std.debug.print("    slm={d}  {d}x{d}  offset=({d},{d})nm\n", .{
                slm.slm_id,       slm.num_row,      slm.num_col,
                slm.offset_nm[0], slm.offset_nm[1],
            });
        }
        std.debug.print("  Readout:      zone={d}  slm={d}  {d}x{d} traps  offset=({d},{d})nm\n", .{
            s.readout_zone.zone_id,
            s.readout_zone.slm.slm_id,
            s.readout_zone.slm.num_row,
            s.readout_zone.slm.num_col,
            s.readout_zone.offset_nm[0],
            s.readout_zone.offset_nm[1],
        });
        std.debug.print("  Constraints:  blockade={d}nm  zone_gap={d}nm\n", .{
            s.constraints.db_nm,
            s.constraints.dz_nm,
        });
    }
};

/// Loads an architecture config from a TOML file, converts it to integer-nm
/// form, and validates it. A malformed config is a load-time error here, not
/// an index-out-of-bounds panic deep in scheduling.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ArchConfig {
    var parser = toml.Parser(RawArchConfig).init(gpa);
    defer parser.deinit();

    var raw = try parser.parseFile(io, path);
    defer raw.deinit();

    const cfg = try convertConfig(raw.value, gpa);
    errdefer cfg.deinit(gpa);

    try validate(cfg);

    return cfg;
}

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{
    InvalidAodLimits,
    TooFewComputeSlms,
    MismatchedComputeSlms,
    InvalidSlmGrid,
    ZoneGapTooSmall,
    BlockadeGeometry,
};

/// Suppresses validation diagnostics; same pattern as verify.quiet (tests
/// that assert on expected config errors set this).
pub var quiet: bool = false;

fn cfail(comptime fmt: []const u8, args: anytype) void {
    trace.diag(quiet, "arch config: " ++ fmt, args);
}

/// Structural legality of a converted config.
/// Everything the scheduler assumes without checking is rejected here.
pub fn validate(cfg: ArchConfig) ConfigError!void {
    if (cfg.aod.max_num_row == 0 or
        cfg.aod.max_num_col == 0 or
        cfg.aod.min_sep_nm == 0)
    {
        cfail("aod limits must be > 0 (rows={d} cols={d} min_sep={d}nm)", .{
            cfg.aod.max_num_row, cfg.aod.max_num_col, cfg.aod.min_sep_nm,
        });
        return error.InvalidAodLimits;
    }

    try validateSlm("storage", cfg.storage_zone.slm);
    try validateSlm("readout", cfg.readout_zone.slm);

    // The scheduler pairs Rydberg sites from slms[0] and slms[1] unconditionally.
    if (cfg.compute_zone.slms.len < 2) {
        cfail("compute zone needs at least 2 SLMs for Rydberg site pairing, got {d}", .{
            cfg.compute_zone.slms.len,
        });
        return error.TooFewComputeSlms;
    }
    for (cfg.compute_zone.slms) |slm| {
        try validateSlm("compute", slm);
    }

    // Sites are paired by (row, col) index across slms[0] and slms[1], with
    // no bounds check downstream: the two grids must be congruent, or gates
    // beyond the smaller grid land on traps that don't exist.
    const pair_a = cfg.compute_zone.slms[0];
    const pair_b = cfg.compute_zone.slms[1];
    if (pair_a.num_row != pair_b.num_row or
        pair_a.num_col != pair_b.num_col or
        pair_a.sep_nm[0] != pair_b.sep_nm[0] or
        pair_a.sep_nm[1] != pair_b.sep_nm[1])
    {
        cfail("Rydberg pair SLMs {d} and {d} must be congruent grids, got {d}x{d} sep=({d},{d})nm vs {d}x{d} sep=({d},{d})nm", .{
            pair_a.slm_id,
            pair_b.slm_id,
            pair_a.num_row,
            pair_a.num_col,
            pair_a.sep_nm[0],
            pair_a.sep_nm[1],
            pair_b.num_row,
            pair_b.num_col,
            pair_b.sep_nm[0],
            pair_b.sep_nm[1],
        });
        return error.MismatchedComputeSlms;
    }

    // Zones must keep the configured inter-zone gap so the Rydberg laser
    // cannot stray into storage or readout. Boxes derive from the trap
    // grids, so this bounds gap_um from below: it must cover dz plus the
    // half-sep margins of the facing zones. (storage <-> readout follows
    // from the vertical stacking.)
    const dz: i64 = cfg.constraints.dz_nm;
    try requireGap("storage", cfg.storage_zone.box(), "compute", cfg.compute_zone.box(), dz);
    try requireGap("compute", cfg.compute_zone.box(), "readout", cfg.readout_zone.box(), dz);

    // A Rydberg pair must sit within the blockade radius; neighbouring sites
    // must sit outside it.
    if (cfg.compute_zone.dr_nm >= cfg.constraints.db_nm or
        cfg.compute_zone.dw_nm <= cfg.constraints.db_nm)
    {
        cfail("blockade geometry requires dr < db < dw, got dr={d}nm db={d}nm dw={d}nm", .{
            cfg.compute_zone.dr_nm, cfg.constraints.db_nm, cfg.compute_zone.dw_nm,
        });
        return error.BlockadeGeometry;
    }
}

fn validateSlm(zone: []const u8, slm: Slm) ConfigError!void {
    if (slm.num_row == 0 or
        slm.num_col == 0 or
        slm.sep_nm[0] == 0 or
        slm.sep_nm[1] == 0)
    {
        cfail("{s} slm {d}: rows, cols, and separations must be positive", .{ zone, slm.slm_id });
        return error.InvalidSlmGrid;
    }
}

fn requireGap(
    a_name: []const u8,
    a: ZoneBox,
    b_name: []const u8,
    b: ZoneBox,
    gap: i64,
) ConfigError!void {
    const separated =
        @as(i64, a.max[0]) + gap <= b.min[0] or
        @as(i64, b.max[0]) + gap <= a.min[0] or
        @as(i64, a.max[1]) + gap <= b.min[1] or
        @as(i64, b.max[1]) + gap <= a.min[1];
    if (!separated) {
        cfail("{s} and {s} zones overlap or sit closer than dz={d}nm", .{ a_name, b_name, gap });
        return error.ZoneGapTooSmall;
    }
}

// ── Conversion: um (f64) -> nm (integer) ─────────────────────────────────────

// @round, not bare @intFromFloat: truncation silently loses a nanometre
// whenever the product lands a hair under an integer (1.001 um -> 1000 nm).
fn umToNm(um: f64) u32 {
    return @intFromFloat(@round(um * 1000.0));
}

fn umToNmSigned(um: f64) i32 {
    return @intFromFloat(@round(um * 1000.0));
}

fn convertSlm(raw: RawSlm) Slm {
    return .{
        .slm_id = raw.slm_id,
        .num_row = raw.num_row,
        .num_col = raw.num_col,
        .sep_nm = .{
            umToNm(raw.sep_um[0]),
            umToNm(raw.sep_um[1]),
        },
        .offset_nm = .{
            umToNmSigned(raw.offset_um[0]),
            umToNmSigned(raw.offset_um[1]),
        },
    };
}

/// Absolute y of the bottom-most trap row across `slms` for a zone at `zone_y`.
fn lastRowY(zone_y: i32, slms: []const Slm) i32 {
    var last = zone_y;
    for (slms, 0..) |slm, i| {
        const span = @as(i32, @intCast(slm.num_row -| 1)) * @as(i32, @intCast(slm.sep_nm[1]));
        const y = zone_y + slm.offset_nm[1] + span;
        last = if (i == 0) y else @max(last, y);
    }
    return last;
}

/// Zone-relative y of the top-most trap row across `slms`.
fn firstRowOffsetY(slms: []const Slm) i32 {
    var first: i32 = 0;
    for (slms, 0..) |slm, i| {
        first = if (i == 0) slm.offset_nm[1] else @min(first, slm.offset_nm[1]);
    }
    return first;
}

fn convertConfig(raw: RawArchConfig, alloc: std.mem.Allocator) !ArchConfig {
    const name = try alloc.dupe(u8, raw.platform.name);
    errdefer alloc.free(name);

    const version = try alloc.dupe(u8, raw.platform.version);
    errdefer alloc.free(version);

    const slms = try alloc.alloc(Slm, raw.compute_zone.slms.len);
    for (raw.compute_zone.slms, 0..) |raw_slm, i| {
        slms[i] = convertSlm(raw_slm);
    }

    // Zones stack vertically, sharing the storage anchor's x. gap_um is
    // the trap-row flight gap — previous zone's last atom row to this
    // zone's first — so the zone origins are derived, never configured.
    const storage_slm = convertSlm(raw.storage_zone.slm);
    const storage_offset: [2]i32 = .{
        umToNmSigned(raw.storage_zone.offset_um[0]),
        umToNmSigned(raw.storage_zone.offset_um[1]),
    };

    const compute_offset: [2]i32 = .{
        storage_offset[0],
        lastRowY(storage_offset[1], &.{storage_slm}) +
            umToNmSigned(raw.compute_zone.gap_um) - firstRowOffsetY(slms),
    };

    const readout_slm = convertSlm(raw.readout_zone.slm);
    const readout_offset: [2]i32 = .{
        storage_offset[0],
        lastRowY(compute_offset[1], slms) +
            umToNmSigned(raw.readout_zone.gap_um) - readout_slm.offset_nm[1],
    };

    return .{
        .platform = .{
            .name = name,
            .version = version,
        },
        .aod = .{
            .aod_id = raw.aod.aod_id,
            .min_sep_nm = umToNm(raw.aod.min_sep_um),
            .max_num_row = raw.aod.max_num_row,
            .max_num_col = raw.aod.max_num_col,
        },
        .storage_zone = .{
            .zone_id = raw.storage_zone.zone_id,
            .offset_nm = storage_offset,
            .slm = storage_slm,
        },
        .compute_zone = .{
            .zone_id = raw.compute_zone.zone_id,
            .offset_nm = compute_offset,
            .dr_nm = umToNm(raw.compute_zone.dr_um),
            .dw_nm = umToNm(raw.compute_zone.dw_um),
            .slms = slms,
        },
        .readout_zone = .{
            .zone_id = raw.readout_zone.zone_id,
            .offset_nm = readout_offset,
            .slm = readout_slm,
        },
        .constraints = .{
            .db_nm = umToNm(raw.constraints.db_um),
            .dz_nm = umToNm(raw.constraints.dz_um),
        },
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

// Shared baseline for tests across modules: unit-separation 2x4 storage and
// readout grids, three stacked zones at y 0/5000/9000, and a Rydberg pair
// whose padded box spans x 0..4000, y 4800..7200. Callers mutate the
// returned value to vary the knobs they exercise. The SLM fixtures are
// module-level `var`s because ComputeZone.slms is a mutable slice.
pub var test_no_slms: [0]Slm = .{};

pub var test_compute_slms = [2]Slm{
    .{
        .slm_id = 1,
        .num_row = 1,
        .num_col = 2,
        .sep_nm = .{ 2000, 2000 },
        .offset_nm = .{ 1000, 800 },
    },
    .{
        .slm_id = 2,
        .num_row = 1,
        .num_col = 2,
        .sep_nm = .{ 2000, 2000 },
        .offset_nm = .{ 1000, 1200 },
    },
};

pub fn testConfig() ArchConfig {
    const slm = Slm{
        .slm_id = 0,
        .num_row = 2,
        .num_col = 4,
        .sep_nm = .{ 1000, 1000 },
        .offset_nm = .{ 0, 0 },
    };
    return .{
        .platform = .{ .name = "test", .version = "0" },
        .aod = .{
            .aod_id = 0,
            .min_sep_nm = 100,
            .max_num_row = 4,
            .max_num_col = 4,
        },
        .storage_zone = .{
            .zone_id = 0,
            .offset_nm = .{ 0, 0 },
            .slm = slm,
        },
        .compute_zone = .{
            .zone_id = 1,
            .offset_nm = .{ 0, 5000 },
            .dr_nm = 200,
            .dw_nm = 1000,
            .slms = &test_compute_slms,
        },
        .readout_zone = .{
            .zone_id = 2,
            .offset_nm = .{ 0, 9000 },
            .slm = slm,
        },
        .constraints = .{
            .db_nm = 300,
            .dz_nm = 100,
            .one_qubit_gate_fidelity = 1,
            .two_qubit_gate_fidelity = 1,
            .readout_fidelity = 1,
            .db_nm = 3000,
            .dz_nm = 3000,
            .one_qubit_gate_fidelity = 0.999,
            .two_qubit_gate_fidelity = 0.995,
            .readout_fidelity = 0.99,
            .db_nm = 300,
            .dz_nm = 100,
        },
    };
}

test "validate accepts a well-formed config" {
    try validate(testConfig());
}

test "validate rejects mismatched Rydberg pair SLMs" {
    var slms = test_compute_slms;
    slms[1].num_col = 1;
    var cfg = testConfig();
    cfg.compute_zone.slms = &slms;
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.MismatchedComputeSlms, validate(cfg));
}

test "validate rejects a single compute SLM" {
    var cfg = testConfig();
    cfg.compute_zone.slms = test_compute_slms[0..1];
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.TooFewComputeSlms, validate(cfg));
}

test "validate rejects zero trap separation" {
    var cfg = testConfig();
    cfg.storage_zone.slm.sep_nm[0] = 0;
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.InvalidSlmGrid, validate(cfg));
}

test "validate rejects overlapping zones" {
    var cfg = testConfig();
    cfg.compute_zone.offset_nm = .{ 0, 500 }; // on top of the storage grid
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.ZoneGapTooSmall, validate(cfg));
}

test "validate rejects zones closer than the configured gap" {
    var cfg = testConfig();
    // Storage box ends at y=1500; the compute box (pair offset 800 minus
    // 1000 half-sep padding) starts at 1750-200=1550: a 50nm derived gap,
    // under dz=100.
    cfg.compute_zone.offset_nm = .{ 0, 1750 };
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.ZoneGapTooSmall, validate(cfg));
}

test "validate rejects broken blockade geometry" {
    var cfg = testConfig();
    cfg.compute_zone.dw_nm = 300; // site spacing at the blockade radius
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.BlockadeGeometry, validate(cfg));
}

test "validate rejects an out-of-range fidelity" {
    var cfg = testConfig();
    cfg.constraints.readout_fidelity = 1.5;
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.InvalidFidelity, validate(cfg));
}

test "the example config loads and validates" {
    const cfg = try load(std.testing.allocator, std.testing.io, "cfg/arch.toml");
test "the pinned config loads and derives zone offsets" {
    const cfg = try load(std.testing.allocator, std.testing.io, "testdata/arch.toml");
    defer cfg.deinit(std.testing.allocator);

    // gap_um anchors on trap rows: storage's last row (10 rows @ 3um ends
    // at y=27um) + 20um gap puts the compute origin at 47um.
    try std.testing.expectEqual(47_000, cfg.compute_zone.offset_nm[1]);
    // Compute's bottom row (origin 47um + slm offset 2um + 9 rows @ 12um
    // = 157um) + 20um gap puts the readout origin at 177um.
    try std.testing.expectEqual(177_000, cfg.readout_zone.offset_nm[1]);
}

// No geometry assertions: cfg/arch.toml is user-editable for experiments,
// so this only guards against shipping a config that fails to load.
test "the shipped config loads and validates" {
    const cfg = try load(std.testing.allocator, std.testing.io, "cfg/arch.toml");
    cfg.deinit(std.testing.allocator);
}

test "umToNm rounds to the nearest nanometre" {
    try std.testing.expectEqual(3000, umToNm(3.0));
    try std.testing.expectEqual(2300, umToNm(2.3));
    // Regression: truncation would yield 1000 (1.001 * 1000.0 lands a hair
    // under 1001.0 in f64).
    try std.testing.expectEqual(1001, umToNm(1.001));
    try std.testing.expectEqual(-2500, umToNmSigned(-2.5));
    try std.testing.expectEqual(-1001, umToNmSigned(-1.001));
}

test "Grid maps rows and columns to absolute nm coordinates" {
    const g = Grid{
        .origin_nm = .{ 1000, -2000 },
        .sep_nm = .{ 3000, 1000 },
        .num_row = 2,
        .num_col = 4,
    };
    try std.testing.expectEqual(1000, g.x(0));
    try std.testing.expectEqual(7000, g.x(2));
    try std.testing.expectEqual(-2000, g.y(0));
    try std.testing.expectEqual(-1000, g.y(1));
    try std.testing.expectEqual(1500, g.halfSepX());
    try std.testing.expectEqual(-1000, g.bottomRowY());
}

test "zone grids compose the zone offset with the SLM offset" {
    const cfg = testConfig();
    // Compute SLM 1 sits at (1000, 1200) from the zone's bottom-left corner.
    const g = cfg.compute_zone.grid(1);
    try std.testing.expectEqual(1000, g.x(0));
    try std.testing.expectEqual(6200, g.y(0)); // zone y 5000 + slm offset 1200
}

test "corridorY lies in the trap-free lane between storage and compute" {
    const cfg = try load(std.testing.allocator, std.testing.io, "testdata/arch.toml");
    defer cfg.deinit(std.testing.allocator);

    const cy = cfg.corridorY();
    try std.testing.expect(cy > cfg.storage_zone.grid().bottomRowY());
    try std.testing.expect(cy < cfg.compute_zone.grid(0).y(0));
}

test {
    std.testing.refAllDecls(@This());
}
