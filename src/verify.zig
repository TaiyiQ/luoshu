//! Legality verifier for hardware schedules.
//!
//! Replays the frame stream against the initial placement, tracking each
//! qubit's trap state (SLM or AOD) and position, and checks:
//!
//!  - trap-state machine: load only from SLM, move/store only from AOD,
//!    every atom back in an SLM trap at the end of the schedule;
//!  - op coherence: move sources match the replayed positions, moves are
//!    axis-aligned (Manhattan), raman targets match the replayed positions;
//!  - path legality: no move sweeps through a trap site that is occupied
//!    for the whole frame (ops within a frame execute in parallel, so an
//!    atom loaded in the same frame lifts with the sweep and is no obstacle);
//!  - trap sweeps: no move sweeps a storage- or readout-zone trap site,
//!    occupied or empty — an AOD atom dragged across an SLM potential risks
//!    a trap handoff, so travel happens in gap midpoints and lanes. The
//!    compute zone is exempt: the dip choreography deliberately slides
//!    within its rows;
//!  - site exclusivity: no two atoms on the same site at the end of a frame;
//!  - AOD rigidity: two atoms held in the AOD never invert their relative
//!    x or y order within a frame (AOD rows/columns cannot cross);
//!  - AOD hardware limits: held atoms never occupy more rows/columns than
//!    `cfg.aod` allows, and no two AOD rows or columns sit closer than
//!    `min_sep_nm`;
//!  - single AOD row: the physical AOD drives one row tone, so all held
//!    atoms share one y at the end of every frame (vertical register
//!    moves are register-wide; only column tones move per-atom);
//!  - blockade: during a rydberg pulse, no atom in the illuminated zone has
//!    more than one neighbour within the blockade radius `db_nm`;
//!  - pair intent: every routed CZ pair carried on a rydberg op lies within
//!    `db_nm` at pulse time (a pair parked farther apart entangles nothing,
//!    legally — this is the check that proves the pulse does what the
//!    router asked);
//!  - CZ coverage: the multiset of pairs carried on rydberg ops equals the
//!    requested CZ list the caller passes in. Every other check audits the
//!    schedule's own claims, so this is what catches a silently dropped
//!    gate. A circuit that repeats a pair within one stage fails here by
//!    design: routing's interaction graph deduplicates, and CZ^2 = I makes
//!    that dedup semantically lossy;
//!  - measurement: measured qubits lie inside the named zone;
//!  - reset: reset qubits sit in an SLM trap and lie inside the named zone.
//!
//! Any violation prints a diagnostic naming the frame and returns an error.
//! Run after Pipeline.compile in debug builds and in every test, so routing
//! bugs surface as failing assertions instead of animation glitches.

const std = @import("std");
const schedule = @import("schedule");
const arch = @import("arch");
const trace = @import("trace");

const Point = schedule.Point;

const Trap = enum { slm, aod };

const MoveRec = struct { q: usize, src: Point, dest: Point };

pub fn verify(
    gpa: std.mem.Allocator,
    hw: *const schedule.Hardware,
    wanted_cz: []const [2]u32,
) !void {
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

        try replayOps(gpa, t, frame, n, pos, trap, &moves);
        try checkPathLegality(t, n, moves.items, start_trap, trap, pos);
        try checkTrapSweeps(t, hw.cfg, moves.items);
        try checkSiteExclusivity(t, n, pos, &occupied);
        try checkAodRigidity(t, n, start_pos, pos, trap);
        try checkAodLimits(t, n, hw.cfg.aod, pos, trap);
        try checkZones(t, n, hw.cfg, frame, pos);
    }

    try checkTerminalState(hw.frames.items.len, n, trap);
    try checkCzCoverage(gpa, hw, wanted_cz);
}

fn pairLessThan(_: void, a: [2]u32, b: [2]u32) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    return a[1] < b[1];
}

/// The multiset of CZ pairs recorded on the schedule's rydberg ops must
/// equal the requested gates. Pair intent proves each recorded pair is
/// physically entangled; this proves the recorded pairs are the ones the
/// circuit asked for, so a silently dropped gate cannot verify.
fn checkCzCoverage(
    gpa: std.mem.Allocator,
    hw: *const schedule.Hardware,
    wanted_cz: []const [2]u32,
) !void {
    const wanted = try gpa.dupe([2]u32, wanted_cz);
    defer gpa.free(wanted);

    var got: std.ArrayList([2]u32) = .empty;
    defer got.deinit(gpa);
    for (hw.frames.items) |frame| {
        for (frame.items) |op| {
            if (op != .rydberg) continue;
            for (op.rydberg.pairs) |p|
                try got.append(gpa, .{ @min(p[0], p[1]), @max(p[0], p[1]) });
        }
    }

    std.mem.sort([2]u32, wanted, {}, pairLessThan);
    std.mem.sort([2]u32, got.items, {}, pairLessThan);

    if (!std.mem.eql([2]u32, wanted, got.items)) {
        trace.diag(quiet, "schedule verify: CZ coverage mismatch: circuit wants {any}, schedule entangles {any}", .{ wanted, got.items });
        return error.CzCoverageMismatch;
    }
}

/// Replays one frame's ops in emission order: trap-state machine (load only
/// from SLM, move/store only from AOD) and op coherence (move sources match
/// the replayed positions, moves are axis-aligned, raman targets match).
/// Mutates `pos`/`trap` in place and records the frame's moves.
fn replayOps(
    gpa: std.mem.Allocator,
    t: usize,
    frame: schedule.Frame,
    n: usize,
    pos: []Point,
    trap: []Trap,
    moves: *std.ArrayList(MoveRec),
) !void {
    for (frame.items) |op| {
        switch (op) {
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
                // Single row tone: the trap must form on the atom, and
                // every held column rides the same tone, so the load's
                // row must be inline with the whole register at this
                // instant — not merely by end of frame.
                for (0..n) |r| {
                    if (trap[r] != .aod) continue;
                    if (pos[r].y != ld.position.y) {
                        vfail(t, "load of qubit {d} at y={d} while held qubit {d} is at y={d}", .{
                            q, ld.position.y, r, pos[r].y,
                        });
                        return error.LoadOffRegisterRow;
                    }
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
            .reset => |r| {
                for (r.qubits) |raw| {
                    const q = try qubitIndex(t, raw, n);
                    if (trap[q] != .slm) {
                        vfail(t, "reset of qubit {d} while held in the AOD", .{q});
                        return error.ResetWhileInAod;
                    }
                }
            },
            // Checked at end of frame, once all positions are settled.
            .rydberg, .measure => {},
        }
    }
}

/// No move sweeps through a trap site that is occupied for the whole frame
/// (ops within a frame execute in parallel, so an atom loaded in the same
/// frame lifts with the sweep and is no obstacle).
fn checkPathLegality(
    t: usize,
    n: usize,
    moves: []const MoveRec,
    start_trap: []const Trap,
    trap: []const Trap,
    pos: []const Point,
) !void {
    for (moves) |mv| {
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
}

/// No move sweeps a storage- or readout-zone trap site, occupied or empty:
/// an AOD atom dragged across an SLM potential risks a trap handoff, so
/// travel happens in gap midpoints and lanes. The compute zone is exempt —
/// the dip choreography deliberately slides within its rows.
fn checkTrapSweeps(t: usize, cfg: arch.ArchConfig, moves: []const MoveRec) !void {
    const grids = [_]arch.Grid{
        cfg.storage_zone.grid(),
        cfg.readout_zone.grid(),
    };
    for (moves) |mv| {
        for (grids) |g| {
            const site: ?Point = if (mv.src.y == mv.dest.y) horiz: {
                // A horizontal move sweeps a site iff it rides exactly on a
                // trap row and a trap column lies strictly between its ends.
                if (gridIndex(g.origin_nm[1], g.sep_nm[1], g.num_row, mv.src.y) == null)
                    break :horiz null;
                const col = indexBetween(g.origin_nm[0], g.sep_nm[0], g.num_col, mv.src.x, mv.dest.x) orelse
                    break :horiz null;
                break :horiz .{ .x = g.x(col), .y = mv.src.y };
            } else vert: {
                if (gridIndex(g.origin_nm[0], g.sep_nm[0], g.num_col, mv.src.x) == null)
                    break :vert null;
                const row = indexBetween(g.origin_nm[1], g.sep_nm[1], g.num_row, mv.src.y, mv.dest.y) orelse
                    break :vert null;
                break :vert .{ .x = mv.src.x, .y = g.y(row) };
            };
            if (site) |p| {
                vfail(t, "qubit {d} moves ({d},{d}) -> ({d},{d}) across the trap site at ({d},{d})", .{
                    mv.q, mv.src.x, mv.src.y, mv.dest.x, mv.dest.y, p.x, p.y,
                });
                return error.SweptTrapSite;
            }
        }
    }
}

/// Index of the grid line sitting exactly at `v`, if any.
fn gridIndex(origin: i32, sep: i32, n: u32, v: i32) ?usize {
    const rel = v - origin;
    if (@mod(rel, sep) != 0) return null;
    const i = @divExact(rel, sep);
    if (i < 0 or i >= n) return null;
    return @intCast(i);
}

/// Index of the first grid line strictly between `a` and `b`, if any.
fn indexBetween(origin: i32, sep: i32, n: u32, a: i32, b: i32) ?usize {
    const lo = @min(a, b);
    const hi = @max(a, b);
    var first = @divFloor(lo - origin, sep) + 1;
    if (first < 0) first = 0;
    if (first >= n) return null;
    if (origin + first * sep >= hi) return null;
    return @intCast(first);
}

/// No two atoms on the same site at the end of a frame.
fn checkSiteExclusivity(
    t: usize,
    n: usize,
    pos: []const Point,
    occupied: *std.AutoHashMap(Point, usize),
) !void {
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
}

/// Two atoms held in the AOD never invert their relative x or y order within
/// a frame (AOD rows/columns cannot cross).
fn checkAodRigidity(
    t: usize,
    n: usize,
    start_pos: []const Point,
    pos: []const Point,
    trap: []const Trap,
) !void {
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
}

/// Held atoms sit on row/column intersections, so distinct x values are AOD
/// columns and distinct y values AOD rows. Hardware limits both their count
/// and their pitch. Also enforces the single physical row tone: every held
/// atom shares one y once the frame settles (the pickup choreography rides
/// the register between storage rows as a unit).
fn checkAodLimits(
    t: usize,
    n: usize,
    aod: arch.HardwareAod,
    pos: []const Point,
    trap: []const Trap,
) !void {
    var cols: usize = 0;
    var rows: usize = 0;
    for (0..n) |a| {
        if (trap[a] != .aod) continue;
        var new_col = true;
        var new_row = true;
        for (0..a) |b| {
            if (trap[b] != .aod) continue;
            if (pos[b].x == pos[a].x) new_col = false;
            if (pos[b].y == pos[a].y) new_row = false;
            const dx = @abs(@as(i64, pos[a].x) - pos[b].x);
            const dy = @abs(@as(i64, pos[a].y) - pos[b].y);
            if ((dx != 0 and dx < aod.min_sep_nm) or (dy != 0 and dy < aod.min_sep_nm)) {
                vfail(t, "AOD qubits {d} and {d} at ({d},{d})/({d},{d}) closer than min_sep={d}nm", .{
                    b, a, pos[b].x, pos[b].y, pos[a].x, pos[a].y, aod.min_sep_nm,
                });
                return error.AodSeparationViolation;
            }
        }
        if (new_col) cols += 1;
        if (new_row) rows += 1;
    }
    if (cols > aod.max_num_col or rows > aod.max_num_row) {
        vfail(t, "AOD holds {d} columns x {d} rows, hardware limit is {d}x{d}", .{
            cols, rows, aod.max_num_col, aod.max_num_row,
        });
        return error.AodCapacityExceeded;
    }

    if (rows > 1) {
        var first: ?usize = null;
        for (0..n) |a| {
            if (trap[a] != .aod) continue;
            const f = first orelse {
                first = a;
                continue;
            };
            if (pos[a].y != pos[f].y) {
                vfail(t, "AOD register split across rows: qubits {d} (y={d}) and {d} (y={d})", .{
                    f, pos[f].y, a, pos[a].y,
                });
                break;
            }
        }
        return error.AodRowSplit;
    }
}

/// Rydberg pulses stay within the blockade radius and reach the pairs the
/// router intended; measured qubits lie inside their zone. Checked once per
/// frame, at settled positions.
fn checkZones(
    t: usize,
    n: usize,
    cfg: arch.ArchConfig,
    frame: schedule.Frame,
    pos: []const Point,
) !void {
    for (frame.items) |op| {
        switch (op) {
            .rydberg => |r| {
                try checkPairs(t, cfg, pos, r.pairs, n);
                try checkBlockade(t, cfg, pos, r.zone);
            },
            .measure => |m| {
                const bounds = zoneBounds(cfg, m.zone);
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
            .reset => |r| {
                const bounds = zoneBounds(cfg, r.zone);
                for (r.qubits) |raw| {
                    const q = try qubitIndex(t, raw, n);
                    if (!contains(bounds, pos[q])) {
                        vfail(t, "reset qubit {d} at ({d},{d}) outside its zone", .{
                            q, pos[q].x, pos[q].y,
                        });
                        return error.ResetOutsideZone;
                    }
                }
            },
            else => {},
        }
    }
}

/// Every atom must be deposited back into an SLM trap by the end of the
/// schedule.
fn checkTerminalState(t: usize, n: usize, trap: []const Trap) !void {
    for (0..n) |q| {
        if (trap[q] != .slm) {
            vfail(t, "qubit {d} still in AOD at end of schedule", .{q});
            return error.AtomLeftInAod;
        }
    }
}

/// Suppresses violation diagnostics. Tests that assert on *expected*
/// violations set this so expected failures don't spam the build output
/// (the build runner displays any test stderr, success or not).
pub var quiet: bool = false;

fn vfail(t: usize, comptime fmt: []const u8, args: anytype) void {
    trace.diag(quiet, "schedule verify: frame {d}: " ++ fmt, .{t} ++ args);
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
    const box = switch (zone) {
        .storage => cfg.storage_zone.box(),
        .compute => cfg.compute_zone.box(),
        .readout => cfg.readout_zone.box(),
    };
    return .{
        .min = .{ .x = box.min[0], .y = box.min[1] },
        .max = .{ .x = box.max[0], .y = box.max[1] },
    };
}

fn contains(b: Bounds, p: Point) bool {
    return p.x >= b.min.x and
        p.x <= b.max.x and
        p.y >= b.min.y and
        p.y <= b.max.y;
}

// The dual of checkBlockade: the pulse must also reach the pairs it was
// emitted for. A routed pair parked farther apart than the blockade radius
// is a schedule that legally entangles nothing.
//
// This validates the schedule against its *own recorded claim*: the pairs
// were computed by moveAodCompute from the same inputs as the placement,
// so a bug that corrupts recording and placement consistently passes here,
// and a pulse that was never emitted leaves nothing to check. That end of
// the contract is held by schedule.zig's expectRydbergPairsWithinBlockade,
// which derives the intent independently from (fixed, moveable) and counts
// the pulses. Breadth here (every schedule, trusted claim); depth there
// (one scenario, untrusted claim).
fn checkPairs(t: usize, cfg: arch.ArchConfig, pos: []const Point, pairs: []const [2]u32, n: usize) !void {
    const db: i64 = cfg.constraints.db_nm;
    const db2 = db * db;

    for (pairs) |pair| {
        const a = try qubitIndex(t, pair[0], n);
        const b = try qubitIndex(t, pair[1], n);

        const dx = @as(i64, pos[a].x) - pos[b].x;
        const dy = @as(i64, pos[a].y) - pos[b].y;

        if (dx * dx + dy * dy > db2) {
            vfail(t, "routed pair ({d},{d}) out of blockade range: ({d},{d}) vs ({d},{d}), db={d}nm", .{
                a, b, pos[a].x, pos[a].y, pos[b].x, pos[b].y, cfg.constraints.db_nm,
            });
            return error.PairOutOfBlockadeRange;
        }
    }
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

// arch.testConfig: storage box at y -500..1500, compute box at y 4800..7200
// (Rydberg pair box x 0..4000, covering the y=6000 positions the zone tests
// use), readout box at y 8500..10500, blockade radius 300nm.
fn makeHw(gpa: std.mem.Allocator, initial: []const Point) !schedule.Hardware {
    var hw = schedule.Hardware{
        .gpa = gpa,
        .arena = .init(gpa),
        .cfg = arch.testConfig(),
    };
    hw.initial = try hw.arena.allocator().dupe(Point, initial);
    return hw;
}

fn addFrame(hw: *schedule.Hardware, kinds: []const schedule.OpKind) !void {
    const a = hw.arena.allocator();
    var frame: schedule.Frame = .empty;
    try frame.appendSlice(a, kinds);
    try hw.frames.append(a, frame);
}

fn pt(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}

/// Verifies `hw` against its own rydberg pairs. The legality tests below
/// hand-build schedules with no source circuit and coverage is not their
/// subject; the dedicated coverage tests feed a real mismatch.
fn verifySelf(gpa: std.mem.Allocator, hw: *const schedule.Hardware) !void {
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    for (hw.frames.items) |frame| {
        for (frame.items) |op| {
            if (op != .rydberg) continue;
            try pairs.appendSlice(gpa, op.rydberg.pairs);
        }
    }
    return verify(gpa, hw, pairs.items);
}

test "accepts a legal load-move-store round trip" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 0),
                .dest = pt(0, 500),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 500),
                .dest = pt(2000, 500),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(2000, 500),
                .dest = pt(2000, 0),
            },
        },
        .{
            .store = .{
                .qubit = 0,
                .position = pt(2000, 0),
            },
        },
    });

    try verifySelf(gpa, &hw);
}

test "catches a load while already in the AOD" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.LoadWhileInAod, verifySelf(gpa, &hw));
}

test "catches a move of a stored atom" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 0),
                .dest = pt(1000, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.MoveWhileStored, verifySelf(gpa, &hw));
}

test "catches a move whose source disagrees with the replayed position" {
    const gpa = std.testing.allocator;
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{.{
        .load = .{
            .qubit = 0,
            .position = pt(0, 0),
        },
    }});
    try addFrame(&hw, &.{.{
        .move = .{
            .qubit = 0,
            .src = pt(500, 0),
            .dest = pt(1000, 0),
        },
    }});

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.MoveSourceMismatch, verifySelf(gpa, &hw));
}

test "catches a sweep through an occupied trap site" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(2000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 1,
                .position = pt(2000, 0),
            },
        },
    });

    // Qubit 1 sweeps left through qubit 0's trap at (0,0).
    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 1,
                .src = pt(2000, 0),
                .dest = pt(-2000, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.MoveThroughOccupiedSite, verifySelf(gpa, &hw));
}

test "atoms loaded in the same frame are not path obstacles" {
    const gpa = std.testing.allocator;

    // Mid-gap y so the sweeps cross no trap row — this test is about atom
    // obstacles, not trap sites.
    var hw = try makeHw(gpa, &.{ pt(0, 500), pt(2000, 500) });
    defer hw.deinit();

    // Both lift in the same frame; qubit 1's sweep crosses qubit 0's old
    // position, but qubit 0 lifts with it (and moves out of the way).
    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 500),
            },
        },
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 500),
                .dest = pt(-3000, 500),
            },
        },
        .{
            .load = .{
                .qubit = 1,
                .position = pt(2000, 500),
            },
        },
        .{
            .move = .{
                .qubit = 1,
                .src = pt(2000, 500),
                .dest = pt(-2000, 500),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .store = .{
                .qubit = 0,
                .position = pt(-3000, 500),
            },
        },
        .{
            .store = .{
                .qubit = 1,
                .position = pt(-2000, 500),
            },
        },
    });

    try verifySelf(gpa, &hw);
}

test "catches two atoms on the same site at end of frame" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 1,
                .position = pt(1000, 0),
            },
        },
    });

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 1,
                .src = pt(1000, 0),
                .dest = pt(0, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.SiteConflict, verifySelf(gpa, &hw));
}

test "catches an AOD order inversion" {
    const gpa = std.testing.allocator;

    // Mid-gap y so the moves cross no trap site — this test is about the
    // AOD column order, not trap sweeps.
    var hw = try makeHw(gpa, &.{ pt(0, 500), pt(2000, 500) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 500),
            },
        },
        .{
            .load = .{
                .qubit = 1,
                .position = pt(2000, 500),
            },
        },
    });

    // The two AOD columns cross: 0 < 2000 before, 3000 > 1000 after.
    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 500),
                .dest = pt(3000, 500),
            },
        },
        .{
            .move = .{
                .qubit = 1,
                .src = pt(2000, 500),
                .dest = pt(1000, 500),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.AodOrderInversion, verifySelf(gpa, &hw));
}

test "catches AOD columns closer than the minimum separation" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
        .{
            .load = .{
                .qubit = 1,
                .position = pt(1000, 0),
            },
        },
    });

    // 50nm between the two AOD columns; arch.testConfig's min_sep_nm is 100.
    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 1,
                .src = pt(1000, 0),
                .dest = pt(50, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.AodSeparationViolation, verifySelf(gpa, &hw));
}

test "catches more AOD columns than the hardware has" {
    const gpa = std.testing.allocator;

    // Five distinct columns; arch.testConfig's AOD is 4x4.
    var hw = try makeHw(gpa, &.{
        pt(0, 0),
        pt(1000, 0),
        pt(2000, 0),
        pt(3000, 0),
        pt(4000, 0),
    });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
        .{
            .load = .{
                .qubit = 1,
                .position = pt(1000, 0),
            },
        },
        .{
            .load = .{
                .qubit = 2,
                .position = pt(2000, 0),
            },
        },
        .{
            .load = .{
                .qubit = 3,
                .position = pt(3000, 0),
            },
        },
        .{
            .load = .{
                .qubit = 4,
                .position = pt(4000, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.AodCapacityExceeded, verifySelf(gpa, &hw));
}

test "catches an AOD register split across rows" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
        .{
            .load = .{
                .qubit = 1,
                .position = pt(1000, 0),
            },
        },
    });

    // Qubit 1 rises alone: the register would need a second row tone.
    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 1,
                .src = pt(1000, 0),
                .dest = pt(1000, 1000),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.AodRowSplit, verifySelf(gpa, &hw));
}

test "catches a load while the register hovers on another row" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{ pt(0, 0), pt(1000, 0) });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 0),
                .dest = pt(0, -500),
            },
        },
    });

    // Qubit 1 loads at the storage row while qubit 0 hovers in the lane
    // above. Both end the frame on one y, but at load time the single
    // row tone would have to be in two places.
    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 1,
                .position = pt(1000, 0),
            },
        },
        .{
            .move = .{
                .qubit = 1,
                .src = pt(1000, 0),
                .dest = pt(1000, -500),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.LoadOffRegisterRow, verifySelf(gpa, &hw));
}

test "catches an atom left in the AOD at end of schedule" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(error.AtomLeftInAod, verifySelf(gpa, &hw));
}

test "catches a blockade violation during a rydberg pulse" {
    const gpa = std.testing.allocator;

    // Three atoms in a 200nm chain inside the compute zone: the middle one
    // has two neighbours within the 300nm blockade radius.
    var hw = try makeHw(gpa, &.{
        pt(1000, 6000),
        pt(1200, 6000),
        pt(1400, 6000),
    });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .rydberg = .{ .zone = .compute } }});

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.BlockadeViolation, verifySelf(gpa, &hw));
}

test "accepts an isolated pair during a rydberg pulse" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{
        pt(1000, 6000),
        pt(1200, 6000),
        pt(3000, 6000),
    });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .rydberg = .{ .zone = .compute } }});

    try verifySelf(gpa, &hw);
}

test "catches a routed pair parked outside blockade range" {
    const gpa = std.testing.allocator;

    // 1000nm apart with a 300nm blockade radius: legal (no crowding), but
    // the pulse cannot entangle the pair it was emitted for.
    var hw = try makeHw(gpa, &.{
        pt(1000, 6000),
        pt(2000, 6000),
    });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .rydberg = .{
                .zone = .compute,
                .pairs = &.{.{ 0, 1 }},
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.PairOutOfBlockadeRange, verifySelf(gpa, &hw));
}

test "accepts a routed pair within blockade range" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{
        pt(1000, 6000),
        pt(1200, 6000),
    });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .rydberg = .{
                .zone = .compute,
                .pairs = &.{.{ 0, 1 }},
            },
        },
    });

    try verifySelf(gpa, &hw);
}

test "catches a dropped CZ: a wanted pair no rydberg op entangles" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{
        pt(1000, 6000),
        pt(1200, 6000),
    });
    defer hw.deinit();

    try addFrame(&hw, &.{.{ .rydberg = .{ .zone = .compute } }});

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(
        error.CzCoverageMismatch,
        verify(gpa, &hw, &.{.{ 0, 1 }}),
    );
}

test "catches an unrequested CZ: an entangled pair the circuit never asked for" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{
        pt(1000, 6000),
        pt(1200, 6000),
    });
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .rydberg = .{
                .zone = .compute,
                .pairs = &.{.{ 1, 0 }},
            },
        },
    });

    quiet = true;
    defer quiet = false;
    try std.testing.expectError(
        error.CzCoverageMismatch,
        verify(gpa, &hw, &.{}),
    );
}

test "catches a measurement outside its zone" {
    const gpa = std.testing.allocator;

    var measured = [_]u32{0};
    // Atom sits in storage, but the op claims a readout-zone measurement.
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .measure = .{
                .zone = .readout,
                .qubits = try hw.arena.allocator().dupe(u32, &measured),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.MeasureOutsideZone, verifySelf(gpa, &hw));
}

test "catches a reset outside its zone" {
    const gpa = std.testing.allocator;

    var reset_q = [_]u32{0};
    // Atom sits in storage, but the op claims a readout-zone reset.
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .reset = .{
                .zone = .readout,
                .qubits = try hw.arena.allocator().dupe(u32, &reset_q),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.ResetOutsideZone, verifySelf(gpa, &hw));
}

test "catches a reset of a qubit held in the AOD" {
    const gpa = std.testing.allocator;

    var reset_q = [_]u32{0};
    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{
            .load = .{
                .qubit = 0,
                .position = pt(0, 0),
            },
        },
        .{
            .reset = .{
                .zone = .storage,
                .qubits = try hw.arena.allocator().dupe(u32, &reset_q),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.ResetWhileInAod, verifySelf(gpa, &hw));
}

test "catches a sweep along a storage row across an empty trap site" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{ .load = .{ .qubit = 0, .position = pt(0, 0) } },
    });

    // Slides on the y=0 trap row across the empty site at (1000,0). No
    // atom is hit, but the trap potential is.
    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 0),
                .dest = pt(2000, 0),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.SweptTrapSite, verifySelf(gpa, &hw));
}

test "catches a descent along a storage column through an empty trap site" {
    const gpa = std.testing.allocator;

    var hw = try makeHw(gpa, &.{pt(0, 0)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{ .load = .{ .qubit = 0, .position = pt(0, 0) } },
    });

    // Rides the x=0 trap column through the empty site at (0,1000).
    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(0, 0),
                .dest = pt(0, 2000),
            },
        },
    });

    quiet = true;
    defer quiet = false;

    try std.testing.expectError(error.SweptTrapSite, verifySelf(gpa, &hw));
}

// The compute zone is exempt from the trap-sweep rule: the dip choreography
// (sweepMoveableRows) deliberately slides atoms within its rows.
test "accepts a slide along a compute row" {
    const gpa = std.testing.allocator;

    // testConfig compute SLM(0): one row at y=5800, columns at x=1000, 3000.
    var hw = try makeHw(gpa, &.{pt(1000, 5800)});
    defer hw.deinit();

    try addFrame(&hw, &.{
        .{ .load = .{ .qubit = 0, .position = pt(1000, 5800) } },
    });

    try addFrame(&hw, &.{
        .{
            .move = .{
                .qubit = 0,
                .src = pt(1000, 5800),
                .dest = pt(3000, 5800),
            },
        },
        .{ .store = .{ .qubit = 0, .position = pt(3000, 5800) } },
    });

    try verifySelf(gpa, &hw);
}

test {
    std.testing.refAllDecls(@This());
}
