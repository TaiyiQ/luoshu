//! Legality verifier for hardware schedules (§2 in REFACTORING.md).
//!
//! Replays the frame stream against the initial placement, tracking each
//! qubit's trap state (SLM or AOD) and position, and checks:
//!
//!  - trap-state machine: load only from SLM, move/store only from AOD,
//!    every atom back in an SLM trap at the end of the schedule;
//!  - op coherence: frame stamps match the frame index, move sources match
//!    the replayed positions, moves are axis-aligned (Manhattan), raman
//!    targets match the replayed positions;
//!  - path legality: no move sweeps through a trap site that is occupied
//!    for the whole frame (ops within a frame execute in parallel, so an
//!    atom loaded in the same frame lifts with the sweep and is no obstacle);
//!  - site exclusivity: no two atoms on the same site at the end of a frame;
//!  - AOD rigidity: two atoms held in the AOD never invert their relative
//!    x or y order within a frame (AOD rows/columns cannot cross);
//!  - blockade: during a rydberg pulse, no atom in the illuminated zone has
//!    more than one neighbour within the blockade radius `db_nm`;
//!  - measurement: measured qubits lie inside the named zone.
//!
//! Any violation prints a diagnostic naming the frame and returns an error.
//! Run after Pipeline.compile in debug builds and in every test, so routing
//! bugs surface as failing assertions instead of animation glitches.

const std = @import("std");
const schedule = @import("schedule");
const arch = @import("arch");

const Point = schedule.Point;

const Trap = enum { slm, aod };

const MoveRec = struct { q: usize, src: Point, dest: Point };

pub fn verify(gpa: std.mem.Allocator, hw: *const schedule.Hardware) !void {
    const n = hw.initial.len;

    const pos = try gpa.alloc(Point, n);
    defer gpa.free(pos);
    @memcpy(pos, hw.initial);

    const trap = try gpa.alloc(Trap, n);
    defer gpa.free(trap);
    @memset(trap, .slm);

    const start_pos = try gpa.alloc(Point, n);
    defer gpa.free(start_pos);
    const start_trap = try gpa.alloc(Trap, n);
    defer gpa.free(start_trap);

    var moves: std.ArrayList(MoveRec) = .empty;
    defer moves.deinit(gpa);

    var occupied = std.AutoHashMap(Point, usize).init(gpa);
    defer occupied.deinit();

    for (hw.frames.items, 0..) |frame, t| {
        @memcpy(start_pos, pos);
        @memcpy(start_trap, trap);
        moves.clearRetainingCapacity();

        // Replay ops in emission order: trap-state machine and op coherence.
        for (frame.items) |op| {
            if (op.t != t) {
                vfail(t, "op stamped with t={d}", .{op.t});
                return error.FrameIndexMismatch;
            }
            switch (op.kind) {
                .load => |ld| {
                    const q = try qubitIndex(t, ld.qubit, n);
                    if (trap[q] != .slm) {
                        vfail(t, "load of qubit {d} while already in AOD", .{q});
                        return error.LoadWhileInAod;
                    }
                    if (!eql(pos[q], ld.position)) {
                        vfail(t, "load of qubit {d} at ({d},{d}) but atom is at ({d},{d})", .{
                            q, ld.position.x, ld.position.y, pos[q].x, pos[q].y,
                        });
                        return error.LoadPositionMismatch;
                    }
                    trap[q] = .aod;
                },
                .store => |st| {
                    const q = try qubitIndex(t, st.qubit, n);
                    if (trap[q] != .aod) {
                        vfail(t, "store of qubit {d} while not in AOD", .{q});
                        return error.StoreWhileStored;
                    }
                    if (!eql(pos[q], st.position)) {
                        vfail(t, "store of qubit {d} at ({d},{d}) but atom is at ({d},{d})", .{
                            q, st.position.x, st.position.y, pos[q].x, pos[q].y,
                        });
                        return error.StorePositionMismatch;
                    }
                    trap[q] = .slm;
                },
                .move => |m| {
                    const q = try qubitIndex(t, m.qubit, n);
                    if (trap[q] != .aod) {
                        vfail(t, "move of qubit {d} while not in AOD", .{q});
                        return error.MoveWhileStored;
                    }
                    if (!eql(pos[q], m.src)) {
                        vfail(t, "move of qubit {d} from ({d},{d}) but atom is at ({d},{d})", .{
                            q, m.src.x, m.src.y, pos[q].x, pos[q].y,
                        });
                        return error.MoveSourceMismatch;
                    }
                    if (m.src.x != m.dest.x and m.src.y != m.dest.y) {
                        vfail(t, "diagonal move of qubit {d}: ({d},{d}) -> ({d},{d})", .{
                            q, m.src.x, m.src.y, m.dest.x, m.dest.y,
                        });
                        return error.DiagonalMove;
                    }
                    try moves.append(gpa, .{ .q = q, .src = m.src, .dest = m.dest });
                    pos[q] = m.dest;
                },
                .raman => |r| {
                    for (r.targets) |target| {
                        const q = try qubitIndex(t, target.qubit, n);
                        if (!eql(pos[q], target.pos)) {
                            vfail(t, "raman target qubit {d} at ({d},{d}) but atom is at ({d},{d})", .{
                                q, target.pos.x, target.pos.y, pos[q].x, pos[q].y,
                            });
                            return error.RamanPositionMismatch;
                        }
                    }
                },
                // Checked at end of frame, once all positions are settled.
                .rydberg, .measure => {},
            }
        }

        // Path legality: a swept segment must not cross a trap site that is
        // occupied for the whole frame.
        for (moves.items) |mv| {
            for (0..n) |r| {
                if (r == mv.q) continue;
                if (start_trap[r] != .slm or trap[r] != .slm) continue;
                if (onOpenSegment(pos[r], mv.src, mv.dest)) {
                    vfail(t, "qubit {d} moves ({d},{d}) -> ({d},{d}) through stored qubit {d} at ({d},{d})", .{
                        mv.q, mv.src.x, mv.src.y, mv.dest.x, mv.dest.y, r, pos[r].x, pos[r].y,
                    });
                    return error.MoveThroughOccupiedSite;
                }
            }
        }

        // Site exclusivity at end of frame.
        occupied.clearRetainingCapacity();
        for (0..n) |q| {
            const gop = try occupied.getOrPut(pos[q]);
            if (gop.found_existing) {
                vfail(t, "qubits {d} and {d} both at ({d},{d})", .{
                    gop.value_ptr.*, q, pos[q].x, pos[q].y,
                });
                return error.SiteConflict;
            }
            gop.value_ptr.* = q;
        }

        // AOD rigidity: held atoms must not invert their relative order.
        for (0..n) |a| {
            if (trap[a] != .aod) continue;
            for (a + 1..n) |b| {
                if (trap[b] != .aod) continue;
                if (inverts(start_pos[a].x, start_pos[b].x, pos[a].x, pos[b].x) or
                    inverts(start_pos[a].y, start_pos[b].y, pos[a].y, pos[b].y))
                {
                    vfail(t, "AOD order inversion between qubits {d} and {d}: ({d},{d})/({d},{d}) -> ({d},{d})/({d},{d})", .{
                        a,              b,              start_pos[a].x, start_pos[a].y,
                        start_pos[b].x, start_pos[b].y, pos[a].x,       pos[a].y,
                        pos[b].x,       pos[b].y,
                    });
                    return error.AodOrderInversion;
                }
            }
        }

        // Zone checks at settled positions.
        for (frame.items) |op| {
            switch (op.kind) {
                .rydberg => |r| try checkBlockade(t, hw.cfg, pos, r.zone),
                .measure => |m| {
                    const bounds = zoneBounds(hw.cfg, m.zone);
                    for (m.qubits) |raw| {
                        const q = try qubitIndex(t, raw, n);
                        if (!contains(bounds, pos[q])) {
                            vfail(t, "measured qubit {d} at ({d},{d}) outside its zone", .{
                                q, pos[q].x, pos[q].y,
                            });
                            return error.MeasureOutsideZone;
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Terminal state: every atom deposited back into an SLM trap.
    for (0..n) |q| {
        if (trap[q] != .slm) {
            vfail(hw.frames.items.len, "qubit {d} still in AOD at end of schedule", .{q});
            return error.AtomLeftInAod;
        }
    }
}

/// Suppresses violation diagnostics. Tests that assert on *expected*
/// violations set this so expected failures don't spam the build output
/// (the build runner displays any test stderr, success or not).
pub var quiet: bool = false;

fn vfail(t: usize, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    std.debug.print("schedule verify: frame {d}: " ++ fmt ++ "\n", .{t} ++ args);
}

fn qubitIndex(t: usize, raw: u32, n: usize) !usize {
    if (raw >= n) {
        vfail(t, "op references qubit {d} but the schedule has {d} qubits", .{ raw, n });
        return error.UnknownQubit;
    }
    return raw;
}

fn eql(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

/// True if `p` lies strictly between `a` and `b` on an axis-aligned segment.
fn onOpenSegment(p: Point, a: Point, b: Point) bool {
    if (a.y == b.y) {
        if (p.y != a.y) return false;
        return p.x > @min(a.x, b.x) and p.x < @max(a.x, b.x);
    }
    if (a.x == b.x) {
        if (p.x != a.x) return false;
        return p.y > @min(a.y, b.y) and p.y < @max(a.y, b.y);
    }
    return false; // diagonal moves are rejected before path checks
}

/// True if the strict ordering of a and b flipped between the two snapshots.
fn inverts(a0: i32, b0: i32, a1: i32, b1: i32) bool {
    return (a0 < b0 and a1 > b1) or (a0 > b0 and a1 < b1);
}

const Bounds = struct { min: Point, max: Point };

fn zoneBounds(cfg: arch.ArchConfig, zone: schedule.Zone) Bounds {
    const offset, const dim = switch (zone) {
        .storage => .{ cfg.storage_zone.offset_nm, cfg.storage_zone.dimension_nm },
        .compute => .{ cfg.compute_zone.offset_nm, cfg.compute_zone.dimension_nm },
        .readout => .{ cfg.readout_zone.offset_nm, cfg.readout_zone.dimension_nm },
    };
    return .{
        .min = .{ .x = offset[0], .y = offset[1] },
        .max = .{
            .x = offset[0] + @as(i32, @intCast(dim[0])),
            .y = offset[1] + @as(i32, @intCast(dim[1])),
        },
    };
}

fn contains(b: Bounds, p: Point) bool {
    return p.x >= b.min.x and p.x <= b.max.x and p.y >= b.min.y and p.y <= b.max.y;
}

// During a rydberg pulse every atom inside the illuminated zone interacts
// with everything within the blockade radius. Pairs are intended (that is
// what the pulse is for); a third atom in range is an unintended gate.
fn checkBlockade(t: usize, cfg: arch.ArchConfig, pos: []const Point, zone: schedule.Zone) !void {
    const bounds = zoneBounds(cfg, zone);
    const db: i64 = cfg.constraints.db_nm;
    const db2 = db * db;

    for (pos, 0..) |pa, a| {
        if (!contains(bounds, pa)) continue;
        var neighbors: usize = 0;
        for (pos, 0..) |pb, b| {
            if (a == b or !contains(bounds, pb)) continue;
            const dx = @as(i64, pa.x) - pb.x;
            const dy = @as(i64, pa.y) - pb.y;
            if (dx * dx + dy * dy <= db2) neighbors += 1;
        }
        if (neighbors > 1) {
            vfail(t, "blockade violation: qubit {d} at ({d},{d}) has {d} atoms within {d}nm", .{
                a, pa.x, pa.y, neighbors, cfg.constraints.db_nm,
            });
            return error.BlockadeViolation;
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

var test_no_slms: [0]arch.Slm = .{};

// Minimal hand-built config: storage at y 0..2000, compute at y 5000..7000,
// readout at y 9000..10000, blockade radius 300nm.
fn testCfg() arch.ArchConfig {
    const slm = arch.Slm{
        .slm_id = 0,
        .num_row = 2,
        .num_col = 4,
        .sep_nm = .{ 1000, 1000 },
        .offset_nm = .{ 0, 0 },
    };
    return .{
        .platform = .{ .name = "test", .version = "0" },
        .aod = .{ .aod_id = 0, .min_sep_nm = 100, .max_num_row = 4, .max_num_col = 4 },
        .storage_zone = .{ .zone_id = 0, .offset_nm = .{ 0, 0 }, .dimension_nm = .{ 4000, 2000 }, .slm = slm },
        .compute_zone = .{ .zone_id = 1, .offset_nm = .{ 0, 5000 }, .dimension_nm = .{ 4000, 2000 }, .dr_nm = 200, .dw_nm = 1000, .slms = &test_no_slms },
        .readout_zone = .{ .zone_id = 2, .offset_nm = .{ 0, 9000 }, .dimension_nm = .{ 4000, 1000 }, .slm = slm },
        .constraints = .{ .db_nm = 300, .dz_nm = 100, .one_qubit_gate_fidelity = 1, .two_qubit_gate_fidelity = 1, .readout_fidelity = 1 },
    };
}

fn makeHw(gpa: std.mem.Allocator, initial: []const Point) !schedule.Hardware {
    var hw = schedule.Hardware{ .gpa = gpa, .cfg = testCfg() };
    hw.initial = try gpa.dupe(Point, initial);
    return hw;
}

fn addFrame(hw: *schedule.Hardware, kinds: []const schedule.OpKind) !void {
    var frame: schedule.Frame = .empty;
    errdefer frame.deinit(hw.gpa);
    const t: u32 = @intCast(hw.frames.items.len);
    for (kinds) |kind| try frame.append(hw.gpa, .{ .t = t, .kind = kind });
    try hw.frames.append(hw.gpa, frame);
}

fn pt(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}

test "accepts a legal load-move-store round trip" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .load = .{ .qubit = 0, .position = pt(0, 0) } }});
    try addFrame(&hw, &.{.{ .move = .{ .qubit = 0, .src = pt(0, 0), .dest = pt(0, 500) } }});
    try addFrame(&hw, &.{.{ .move = .{ .qubit = 0, .src = pt(0, 500), .dest = pt(2000, 500) } }});
    try addFrame(&hw, &.{
        .{ .move = .{ .qubit = 0, .src = pt(2000, 500), .dest = pt(2000, 0) } },
        .{ .store = .{ .qubit = 0, .position = pt(2000, 0) } },
    });

    try verify(gpa, &hw);
}

test "catches a load while already in the AOD" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{ .load = .{ .qubit = 0, .position = pt(0, 0) } },
        .{ .load = .{ .qubit = 0, .position = pt(0, 0) } },
    });

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.LoadWhileInAod, verify(gpa, &hw));
}

test "catches a move of a stored atom" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .move = .{ .qubit = 0, .src = pt(0, 0), .dest = pt(1000, 0) } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.MoveWhileStored, verify(gpa, &hw));
}

test "catches a move whose source disagrees with the replayed position" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .load = .{ .qubit = 0, .position = pt(0, 0) } }});
    try addFrame(&hw, &.{.{ .move = .{ .qubit = 0, .src = pt(500, 0), .dest = pt(1000, 0) } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.MoveSourceMismatch, verify(gpa, &hw));
}

test "catches a sweep through an occupied trap site" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(2000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .load = .{ .qubit = 1, .position = pt(2000, 0) } }});
    // Qubit 1 sweeps left through qubit 0's trap at (0,0).
    try addFrame(&hw, &.{.{ .move = .{ .qubit = 1, .src = pt(2000, 0), .dest = pt(-2000, 0) } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.MoveThroughOccupiedSite, verify(gpa, &hw));
}

test "atoms loaded in the same frame are not path obstacles" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(2000, 0) });
    defer hw.deinit();

    // Both lift in the same frame; qubit 1's sweep crosses qubit 0's old
    // site, but qubit 0 lifts with it (and moves out of the way).
    try addFrame(&hw, &.{
        .{ .load = .{ .qubit = 0, .position = pt(0, 0) } },
        .{ .move = .{ .qubit = 0, .src = pt(0, 0), .dest = pt(-3000, 0) } },
        .{ .load = .{ .qubit = 1, .position = pt(2000, 0) } },
        .{ .move = .{ .qubit = 1, .src = pt(2000, 0), .dest = pt(-2000, 0) } },
    });
    try addFrame(&hw, &.{
        .{ .store = .{ .qubit = 0, .position = pt(-3000, 0) } },
        .{ .store = .{ .qubit = 1, .position = pt(-2000, 0) } },
    });

    try verify(gpa, &hw);
}

test "catches two atoms on the same site at end of frame" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .load = .{ .qubit = 1, .position = pt(1000, 0) } }});
    try addFrame(&hw, &.{.{ .move = .{ .qubit = 1, .src = pt(1000, 0), .dest = pt(0, 0) } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.SiteConflict, verify(gpa, &hw));
}

test "catches an AOD order inversion" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(2000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{ .load = .{ .qubit = 0, .position = pt(0, 0) } },
        .{ .load = .{ .qubit = 1, .position = pt(2000, 0) } },
    });
    // The two AOD columns cross: 0 < 2000 before, 3000 > 1000 after.
    try addFrame(&hw, &.{
        .{ .move = .{ .qubit = 0, .src = pt(0, 0), .dest = pt(3000, 0) } },
        .{ .move = .{ .qubit = 1, .src = pt(2000, 0), .dest = pt(1000, 0) } },
    });

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.AodOrderInversion, verify(gpa, &hw));
}

test "catches an atom left in the AOD at end of schedule" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .load = .{ .qubit = 0, .position = pt(0, 0) } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.AtomLeftInAod, verify(gpa, &hw));
}

test "catches a blockade violation during a rydberg pulse" {
    const gpa = std.testing.allocator;
    // Three atoms in a 200nm chain inside the compute zone: the middle one
    // has two neighbours within the 300nm blockade radius.
    var hw = try makeHw(gpa, &.{ pt(1000, 6000), pt(1200, 6000), pt(1400, 6000) });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .rydberg = .{ .zone = .compute } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.BlockadeViolation, verify(gpa, &hw));
}

test "accepts an isolated pair during a rydberg pulse" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{ pt(1000, 6000), pt(1200, 6000), pt(3000, 6000) });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .rydberg = .{ .zone = .compute } }});

    try verify(gpa, &hw);
}

test "catches a measurement outside its zone" {
    const gpa = std.testing.allocator;
    var measured = [_]u32{0};
    // Atom sits in storage, but the op claims a readout-zone measurement.
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .measure = .{ .zone = .readout, .qubits = try gpa.dupe(u32, &measured) } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.MeasureOutsideZone, verify(gpa, &hw));
}

test {
    @import("testutil").refAllDeclsRecursive(@This());
}
