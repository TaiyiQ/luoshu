const std = @import("std");
const toml = @import("toml");

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
    dimension_um: [2]f64,
    slm: RawSlm,
};

const RawComputeZone = struct {
    zone_id: u32,
    offset_um: [2]f64,
    dimension_um: [2]f64,
    dr_um: f64,
    dw_um: f64,
    slms: []RawSlm,
};

const RawReadoutZone = struct {
    zone_id: u32,
    offset_um: [2]f64,
    dimension_um: [2]f64,
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
    one_qubit_gate_fidelity: f64,
    two_qubit_gate_fidelity: f64,
    readout_fidelity: f64,
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
    dimension_nm: [2]u32,
    slm: Slm,

    pub fn grid(z: StorageZone) Grid {
        return slmGrid(z.offset_nm, z.slm);
    }
};

pub const ComputeZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    dimension_nm: [2]u32,
    dr_nm: u32,
    dw_nm: u32,
    slms: []Slm,

    pub fn grid(z: ComputeZone, slm_idx: usize) Grid {
        return slmGrid(z.offset_nm, z.slms[slm_idx]);
    }
};

pub const ReadoutZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    dimension_nm: [2]u32,
    slm: Slm,

    pub fn grid(z: ReadoutZone) Grid {
        return slmGrid(z.offset_nm, z.slm);
    }
};

pub const Constraints = struct {
    db_nm: u32,
    dz_nm: u32,
    one_qubit_gate_fidelity: f64,
    two_qubit_gate_fidelity: f64,
    readout_fidelity: f64,
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
        std.debug.print("  Fidelities:   1Q={d:.3}  2Q={d:.3}  readout={d:.3}\n", .{
            s.constraints.one_qubit_gate_fidelity,
            s.constraints.two_qubit_gate_fidelity,
            s.constraints.readout_fidelity,
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
    SlmOutsideZone,
    ZonesOverlap,
    BlockadeGeometry,
    InvalidFidelity,
};

/// Suppresses validation diagnostics; same pattern as verify.quiet (tests
/// that assert on expected config errors set this).
pub var quiet: bool = false;

fn cfail(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    std.debug.print("arch config: " ++ fmt ++ "\n", args);
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

    try validateSlm("storage", cfg.storage_zone.slm, cfg.storage_zone.dimension_nm);
    try validateSlm("readout", cfg.readout_zone.slm, cfg.readout_zone.dimension_nm);

    // The scheduler pairs Rydberg sites from slms[0] and slms[1] unconditionally.
    if (cfg.compute_zone.slms.len < 2) {
        cfail("compute zone needs at least 2 SLMs for Rydberg site pairing, got {d}", .{
            cfg.compute_zone.slms.len,
        });
        return error.TooFewComputeSlms;
    }
    for (cfg.compute_zone.slms) |slm| {
        try validateSlm("compute", slm, cfg.compute_zone.dimension_nm);
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

    // Zones must not overlap, and must keep the configured inter-zone gap so
    // the Rydberg laser cannot stray into storage or readout.
    const dz: i64 = cfg.constraints.dz_nm;
    const storage = zoneBox(cfg.storage_zone.offset_nm, cfg.storage_zone.dimension_nm);
    const compute = zoneBox(cfg.compute_zone.offset_nm, cfg.compute_zone.dimension_nm);
    const readout = zoneBox(cfg.readout_zone.offset_nm, cfg.readout_zone.dimension_nm);
    try requireGap("storage", storage, "compute", compute, dz);
    try requireGap("compute", compute, "readout", readout, dz);
    try requireGap("storage", storage, "readout", readout, dz);

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

    const fids = [_]f64{
        cfg.constraints.one_qubit_gate_fidelity,
        cfg.constraints.two_qubit_gate_fidelity,
        cfg.constraints.readout_fidelity,
    };
    for (fids) |f| {
        if (!(f > 0 and f <= 1)) {
            cfail("fidelities must lie in (0, 1], got 1Q={d} 2Q={d} readout={d}", .{
                fids[0], fids[1], fids[2],
            });
            return error.InvalidFidelity;
        }
    }
}

fn validateSlm(zone: []const u8, slm: Slm, dim: [2]u32) ConfigError!void {
    if (slm.num_row == 0 or
        slm.num_col == 0 or
        slm.sep_nm[0] == 0 or
        slm.sep_nm[1] == 0)
    {
        cfail("{s} slm {d}: rows, cols, and separations must be positive", .{ zone, slm.slm_id });
        return error.InvalidSlmGrid;
    }
    const ext_x = @as(i64, slm.offset_nm[0]) + @as(i64, slm.num_col - 1) * slm.sep_nm[0];
    const ext_y = @as(i64, slm.offset_nm[1]) + @as(i64, slm.num_row - 1) * slm.sep_nm[1];
    if (slm.offset_nm[0] < 0 or slm.offset_nm[1] < 0 or ext_x > dim[0] or ext_y > dim[1]) {
        cfail("{s} slm {d}: trap grid extends outside its zone ({d}x{d}nm grid, {d}x{d}nm zone)", .{
            zone, slm.slm_id, ext_x, ext_y, dim[0], dim[1],
        });
        return error.SlmOutsideZone;
    }
}

const ZoneBox = struct { min: [2]i64, max: [2]i64 };

fn zoneBox(offset_nm: [2]i32, dim_nm: [2]u32) ZoneBox {
    return .{
        .min = .{
            offset_nm[0],
            offset_nm[1],
        },
        .max = .{
            offset_nm[0] + @as(i64, dim_nm[0]),
            offset_nm[1] + @as(i64, dim_nm[1]),
        },
    };
}

fn requireGap(
    a_name: []const u8,
    a: ZoneBox,
    b_name: []const u8,
    b: ZoneBox,
    gap: i64,
) ConfigError!void {
    const separated =
        a.max[0] + gap <= b.min[0] or
        b.max[0] + gap <= a.min[0] or
        a.max[1] + gap <= b.min[1] or
        b.max[1] + gap <= a.min[1];
    if (!separated) {
        cfail("{s} and {s} zones overlap or sit closer than dz={d}nm", .{ a_name, b_name, gap });
        return error.ZonesOverlap;
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
        .sep_nm = .{ umToNm(raw.sep_um[0]), umToNm(raw.sep_um[1]) },
        .offset_nm = .{ umToNmSigned(raw.offset_um[0]), umToNmSigned(raw.offset_um[1]) },
    };
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
            .offset_nm = .{
                umToNmSigned(raw.storage_zone.offset_um[0]),
                umToNmSigned(raw.storage_zone.offset_um[1]),
            },
            .dimension_nm = .{
                umToNm(raw.storage_zone.dimension_um[0]),
                umToNm(raw.storage_zone.dimension_um[1]),
            },
            .slm = convertSlm(raw.storage_zone.slm),
        },
        .compute_zone = .{
            .zone_id = raw.compute_zone.zone_id,
            .offset_nm = .{
                umToNmSigned(raw.compute_zone.offset_um[0]),
                umToNmSigned(raw.compute_zone.offset_um[1]),
            },
            .dimension_nm = .{
                umToNm(raw.compute_zone.dimension_um[0]),
                umToNm(raw.compute_zone.dimension_um[1]),
            },
            .dr_nm = umToNm(raw.compute_zone.dr_um),
            .dw_nm = umToNm(raw.compute_zone.dw_um),
            .slms = slms,
        },
        .readout_zone = .{
            .zone_id = raw.readout_zone.zone_id,
            .offset_nm = .{
                umToNmSigned(raw.readout_zone.offset_um[0]),
                umToNmSigned(raw.readout_zone.offset_um[1]),
            },
            .dimension_nm = .{
                umToNm(raw.readout_zone.dimension_um[0]),
                umToNm(raw.readout_zone.dimension_um[1]),
            },
            .slm = convertSlm(raw.readout_zone.slm),
        },
        .constraints = .{
            .db_nm = umToNm(raw.constraints.db_um),
            .dz_nm = umToNm(raw.constraints.dz_um),
            .one_qubit_gate_fidelity = raw.constraints.one_qubit_gate_fidelity,
            .two_qubit_gate_fidelity = raw.constraints.two_qubit_gate_fidelity,
            .readout_fidelity = raw.constraints.readout_fidelity,
        },
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const test_slm = Slm{
    .slm_id = 0,
    .num_row = 2,
    .num_col = 4,
    .sep_nm = .{ 3000, 1000 },
    .offset_nm = .{ 0, 0 },
};

var test_compute_slms = [2]Slm{
    .{
        .slm_id = 1,
        .num_row = 2,
        .num_col = 2,
        .sep_nm = .{ 10000, 10000 },
        .offset_nm = .{ 0, 0 },
    },
    .{
        .slm_id = 2,
        .num_row = 2,
        .num_col = 2,
        .sep_nm = .{ 10000, 10000 },
        .offset_nm = .{ 0, 2000 },
    },
};

fn testCfg() ArchConfig {
    return .{
        .platform = .{ .name = "test", .version = "0" },
        .aod = .{
            .aod_id = 0,
            .min_sep_nm = 1500,
            .max_num_row = 4,
            .max_num_col = 8,
        },
        .storage_zone = .{
            .zone_id = 0,
            .offset_nm = .{ 0, 0 },
            .dimension_nm = .{ 12000, 4000 },
            .slm = test_slm,
        },
        .compute_zone = .{
            .zone_id = 1,
            .offset_nm = .{ 0, 10000 },
            .dimension_nm = .{ 20000, 14000 },
            .dr_nm = 2000,
            .dw_nm = 10000,
            .slms = &test_compute_slms,
        },
        .readout_zone = .{
            .zone_id = 2,
            .offset_nm = .{ 0, 30000 },
            .dimension_nm = .{ 12000, 4000 },
            .slm = test_slm,
        },
        .constraints = .{
            .db_nm = 3000,
            .dz_nm = 3000,
            .one_qubit_gate_fidelity = 0.999,
            .two_qubit_gate_fidelity = 0.995,
            .readout_fidelity = 0.99,
        },
    };
}

test "validate accepts a well-formed config" {
    try validate(testCfg());
}

test "validate rejects mismatched Rydberg pair SLMs" {
    var slms = test_compute_slms;
    slms[1].num_col = 1;
    var cfg = testCfg();
    cfg.compute_zone.slms = &slms;
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.MismatchedComputeSlms, validate(cfg));
}

test "validate rejects a single compute SLM" {
    var cfg = testCfg();
    cfg.compute_zone.slms = test_compute_slms[0..1];
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.TooFewComputeSlms, validate(cfg));
}

test "validate rejects zero trap separation" {
    var cfg = testCfg();
    cfg.storage_zone.slm.sep_nm[0] = 0;
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.InvalidSlmGrid, validate(cfg));
}

test "validate rejects an SLM grid extending outside its zone" {
    var cfg = testCfg();
    cfg.storage_zone.dimension_nm = .{ 4000, 4000 }; // grid is 9000nm wide
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.SlmOutsideZone, validate(cfg));
}

test "validate rejects overlapping zones" {
    var cfg = testCfg();
    cfg.compute_zone.offset_nm = .{ 0, 2000 }; // storage spans y 0..4000
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.ZonesOverlap, validate(cfg));
}

test "validate rejects zones closer than the configured gap" {
    var cfg = testCfg();
    cfg.compute_zone.offset_nm = .{ 0, 5000 }; // 1000nm gap, dz is 3000nm
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.ZonesOverlap, validate(cfg));
}

test "validate rejects broken blockade geometry" {
    var cfg = testCfg();
    cfg.compute_zone.dw_nm = 2000; // site spacing inside the blockade radius
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.BlockadeGeometry, validate(cfg));
}

test "validate rejects an out-of-range fidelity" {
    var cfg = testCfg();
    cfg.constraints.readout_fidelity = 1.5;
    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.InvalidFidelity, validate(cfg));
}

test "the example config loads and validates" {
    const cfg = try load(std.testing.allocator, std.testing.io, "arch.toml");
    defer cfg.deinit(std.testing.allocator);
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
    const cfg = testCfg();
    // Compute SLM 1 sits 2000 nm above the zone's bottom-left corner.
    const g = cfg.compute_zone.grid(1);
    try std.testing.expectEqual(0, g.x(0));
    try std.testing.expectEqual(12000, g.y(0)); // zone y 10000 + slm offset 2000
}

test "corridorY lies in the trap-free lane between storage and compute" {
    const cfg = try load(std.testing.allocator, std.testing.io, "arch.toml");
    defer cfg.deinit(std.testing.allocator);

    const cy = cfg.corridorY();
    try std.testing.expect(cy > cfg.storage_zone.grid().bottomRowY());
    try std.testing.expect(cy < cfg.compute_zone.grid(0).y(0));
}

test {
    std.testing.refAllDecls(@This());
}
