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

const RawEntanglementZone = struct {
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
    entanglement_zone: RawEntanglementZone,
    readout_zone: RawReadoutZone,
    constraints: RawConstraints,
};

// ── Final structs (integers, nm) — used by the rest of the compiler ──────────

const Platform = struct {
    name: []const u8,
    version: []const u8,
};

const Slm = struct {
    slm_id: u32,
    num_row: u32,
    num_col: u32,
    sep_nm: [2]u32,
    offset_nm: [2]i32,
};

const Aod = struct {
    aod_id: u32,
    min_sep_nm: u32,
    max_num_row: u32,
    max_num_col: u32,
};

const StorageZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    dimension_nm: [2]u32,
    slm: Slm,
};

const EntanglementZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    dimension_nm: [2]u32,
    dr_nm: u32,
    dw_nm: u32,
    slms: []Slm,
};

const ReadoutZone = struct {
    zone_id: u32,
    offset_nm: [2]i32,
    dimension_nm: [2]u32,
};

const Constraints = struct {
    db_nm: u32,
    dz_nm: u32,
    one_qubit_gate_fidelity: f64,
    two_qubit_gate_fidelity: f64,
    readout_fidelity: f64,
};

const ArchConfig = struct {
    platform: Platform,
    aod: Aod,
    storage_zone: StorageZone,
    entanglement_zone: EntanglementZone,
    readout_zone: ReadoutZone,
    constraints: Constraints,

    fn print(s: ArchConfig) void {
        std.debug.print("Platform:     {s} v{s}\n", .{
            s.platform.name,
            s.platform.version,
        });
        std.debug.print("AOD:          id={d}  rows={d}  cols={d}  min_sep={d}nm\n", .{
            s.aod.aod_id,
            s.aod.max_num_row,
            s.aod.max_num_col,
            s.aod.min_sep_nm,
        });
        std.debug.print("Storage:      zone={d}  slm={d}  {d}x{d} traps  sep=({d},{d})nm\n", .{
            s.storage_zone.zone_id,
            s.storage_zone.slm.slm_id,
            s.storage_zone.slm.num_row,
            s.storage_zone.slm.num_col,
            s.storage_zone.slm.sep_nm[0],
            s.storage_zone.slm.sep_nm[1],
        });
        std.debug.print("Entanglement: zone={d}  dr={d}nm  dw={d}nm  slms={d}\n", .{
            s.entanglement_zone.zone_id,
            s.entanglement_zone.dr_nm,
            s.entanglement_zone.dw_nm,
            s.entanglement_zone.slms.len,
        });
        for (s.entanglement_zone.slms) |slm| {
            std.debug.print("  slm={d}  {d}x{d}  offset=({d},{d})nm\n", .{
                slm.slm_id,       slm.num_row,      slm.num_col,
                slm.offset_nm[0], slm.offset_nm[1],
            });
        }
        std.debug.print("Readout:      zone={d}  offset=({d},{d})nm\n", .{
            s.readout_zone.zone_id,
            s.readout_zone.offset_nm[0],
            s.readout_zone.offset_nm[1],
        });
        std.debug.print("Constraints:  blockade={d}nm  zone_gap={d}nm\n", .{
            s.constraints.db_nm,
            s.constraints.dz_nm,
        });
        std.debug.print("Fidelities:   1Q={d:.3}  2Q={d:.3}  readout={d:.3}\n", .{
            s.constraints.one_qubit_gate_fidelity,
            s.constraints.two_qubit_gate_fidelity,
            s.constraints.readout_fidelity,
        });
    }
};

// ── Conversion: um (f64) -> nm (integer) ─────────────────────────────────────

fn umToNm(um: f64) u32 {
    return @intFromFloat(um * 1000.0);
}

fn umToNmSigned(um: f64) i32 {
    return @intFromFloat(um * 1000.0);
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
    const slms = try alloc.alloc(Slm, raw.entanglement_zone.slms.len);
    for (raw.entanglement_zone.slms, 0..) |raw_slm, i| {
        slms[i] = convertSlm(raw_slm);
    }

    return .{
        .platform = raw.platform,
        .aod = .{
            .aod_id = raw.aod.aod_id,
            .min_sep_nm = umToNm(raw.aod.min_sep_um),
            .max_num_row = raw.aod.max_num_row,
            .max_num_col = raw.aod.max_num_col,
        },
        .storage_zone = .{
            .zone_id = raw.storage_zone.zone_id,
            .offset_nm = .{ umToNmSigned(raw.storage_zone.offset_um[0]), umToNmSigned(raw.storage_zone.offset_um[1]) },
            .dimension_nm = .{ umToNm(raw.storage_zone.dimension_um[0]), umToNm(raw.storage_zone.dimension_um[1]) },
            .slm = convertSlm(raw.storage_zone.slm),
        },
        .entanglement_zone = .{
            .zone_id = raw.entanglement_zone.zone_id,
            .offset_nm = .{ umToNmSigned(raw.entanglement_zone.offset_um[0]), umToNmSigned(raw.entanglement_zone.offset_um[1]) },
            .dimension_nm = .{ umToNm(raw.entanglement_zone.dimension_um[0]), umToNm(raw.entanglement_zone.dimension_um[1]) },
            .dr_nm = umToNm(raw.entanglement_zone.dr_um),
            .dw_nm = umToNm(raw.entanglement_zone.dw_um),
            .slms = slms,
        },
        .readout_zone = .{
            .zone_id = raw.readout_zone.zone_id,
            .offset_nm = .{ umToNmSigned(raw.readout_zone.offset_um[0]), umToNmSigned(raw.readout_zone.offset_um[1]) },
            .dimension_nm = .{ umToNm(raw.readout_zone.dimension_um[0]), umToNm(raw.readout_zone.dimension_um[1]) },
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
