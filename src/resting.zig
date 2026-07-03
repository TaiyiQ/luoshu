//! Resting-AOD parking: reserve gap slots for AODs that sit out a timestep
//! (computePositions), materialize them as nulls in the SLM array
//! (placeControlQubits), and park the AODs into them per timestep
//! (scheduleTargetQubits).
//!
//! Every function allocates from a caller-owned arena - scratch included,
//! nothing is freed individually. The caller reclaims everything by
//! deiniting the arena (route.Sequence owns it in production).

const std = @import("std");
const trace = @import("trace");

// An active AOD paired with its SLM gate partner at a given timestep.
// Serves as the boundary marker for resting AODs on either side.
const Entangle = struct {
    c_idx: usize, // SLM array index of the bounding atom
    t_idx: usize, // index into active[] of this AOD
};

// Nearest active (gate-engaged) AOD to the left and right of a resting AOD.
// null on either side means no active AOD exists in that direction.
const Interval = struct {
    left: ?Entangle = null,
    right: ?Entangle = null,
};

// Parking constraint: resting AOD must land in one of the gap slots [min_slot, max_slot].
// Gap slot g sits between slm[g-1] and slm[g]; slot 0 is before slm[0], slot n after slm[n-1].
const Constraint = struct {
    min_slot: usize,
    max_slot: usize,

    fn overlaps(self: Constraint, other: Constraint) bool {
        return self.min_slot <= other.max_slot and other.min_slot <= self.max_slot;
    }

    fn width(self: Constraint) usize {
        return self.max_slot - self.min_slot + 1;
    }

    // Narrow to the gap slots valid for both constraints.
    fn intersect(a: Constraint, b: Constraint) Constraint {
        return .{
            .min_slot = @max(a.min_slot, b.min_slot),
            .max_slot = @min(a.max_slot, b.max_slot),
        };
    }
};

// Phase 2 - build one Interval per active[] entry: each resting AOD's nearest
// active (gate-engaged) AOD on both sides, recorded as Entangles via slm
// (qubit label to SLM array index). A side with no active AOD stays null.
fn nearestActive(
    arena: std.mem.Allocator,
    slm: std.AutoHashMap(usize, usize),
    active: []const ?usize,
) ![]Interval {
    const n = active.len;
    const result = try arena.alloc(Interval, n);
    @memset(result, .{});

    var last_active: ?Entangle = null;
    var stack: std.ArrayList(usize) = .empty; // resting AODs awaiting a right boundary

    for (active, 0..) |label, j| {
        if (label) |id| {
            // An active AOD is the right boundary of every resting AOD queued
            // so far, and the left boundary of those that follow.
            const e = Entangle{ .c_idx = slm.get(id).?, .t_idx = j };
            while (stack.pop()) |i| result[i].right = e;
            last_active = e;
        } else {
            // Resting: the left boundary is already known; the right one
            // arrives with the next active AOD, so queue for it.
            result[j].left = last_active;
            try stack.append(arena, j);
        }
    }

    return result;
}

fn sortedCopy(arena: std.mem.Allocator, items: []const Constraint) ![]Constraint {
    const copy = try arena.dupe(Constraint, items);
    std.mem.sort(Constraint, copy, {}, struct {
        fn lt(_: void, a: Constraint, b: Constraint) bool {
            return a.min_slot < b.min_slot;
        }
    }.lt);
    return copy;
}

fn heapOrder(_: void, a: Constraint, b: Constraint) std.math.Order {
    return std.math.order(a.width(), b.width());
}

const Heap = std.PriorityQueue(Constraint, void, heapOrder);

// Phase 3 - merge the current timestep's parking constraints into the
// accumulated set. Each accumulated entry reserves one physical gap slot,
// narrowed to the interval that satisfies every timestep sharing it: AODs
// rest there at different times, so an overlapping new constraint shares
// the slot (intersect), and a non-overlapping one reserves a fresh slot.
// Both sides sweep sorted by min_slot. Updates resting in place.
fn mergeConstraints(
    arena: std.mem.Allocator,
    resting: *std.ArrayList(Constraint),
    gaps: []const Constraint,
) !void {
    const sorted_rest = try sortedCopy(arena, resting.items);
    const sorted_gaps = try sortedCopy(arena, gaps);

    var heap: Heap = .empty;
    var result: std.ArrayList(Constraint) = .empty;

    var i: usize = 0;
    for (sorted_rest) |slot| {
        // Candidates: every new constraint that starts before this entry ends.
        while (i < sorted_gaps.len and sorted_gaps[i].min_slot <= slot.max_slot) : (i += 1) {
            try heap.push(arena, sorted_gaps[i]);
        }

        // A candidate ending before this entry starts can never match a later
        // entry either (they start even further right): flush it as a fresh gap.
        while (heap.peek()) |top| {
            if (top.max_slot >= slot.min_slot) break;
            try result.append(arena, heap.pop().?);
        }

        // Match the narrowest candidate - wider ones have more entries left to
        // fall back on. Popping consumes it: a slot holds one AOD at a time.
        if (heap.pop()) |best| {
            try result.append(arena, slot.intersect(best));
        } else {
            try result.append(arena, slot);
        }
    }

    // Candidates pushed but never matched: no accumulated entry covered them.
    while (heap.pop()) |c| try result.append(arena, c);

    // Candidates never pushed: they start beyond every accumulated entry's end.
    while (i < sorted_gaps.len) : (i += 1) try result.append(arena, sorted_gaps[i]);

    resting.* = result;
}

// Place one null slot per gap into the SLM array, adjacent to a bounding
// engaged partner: immediately left of the right boundary atom (max_slot)
// when one exists, else immediately right of the left boundary (min_slot).
// Keeps resting AODs hugging their active neighbour instead of drifting to
// the array edge, matching scheduleTargetQubits' rightmost-slot preference.
pub fn placeControlQubits(
    arena: std.mem.Allocator,
    slm: []const usize,
    gaps: []const Constraint,
) ![]?usize {
    const n = slm.len;

    // n atoms create n+1 gap slots: one before each atom plus one after the last.
    // nulls[i] = number of null slots to insert before slm[i]; nulls[n] = after slm[n-1].
    const nulls = try arena.alloc(usize, n + 1);
    @memset(nulls, 0);

    // max_slot == n means no right boundary ever constrained this gap.
    for (gaps) |gap| {
        const slot = if (gap.max_slot < n) gap.max_slot else gap.min_slot;
        nulls[slot] += 1;
    }

    var result: std.ArrayList(?usize) = .empty;

    // Insert the nulls parked at slot i (before slm[i]), then the atom itself.
    for (0..n) |i| {
        for (0..nulls[i]) |_| try result.append(arena, null);
        try result.append(arena, slm[i]);
    }

    // Slot n sits after the last atom; flush any nulls parked there.
    for (0..nulls[n]) |_| try result.append(arena, null);

    return result.toOwnedSlice(arena);
}

// Runs Phase 2 (nearestActive) and Phase 3 (mergeConstraints) across all timesteps,
// accumulating the set of gap constraints that must hold simultaneously.
pub fn computePositions(
    arena: std.mem.Allocator,
    slm: []const usize,
    timesteps: []const []const ?usize,
) ![]Constraint {
    // Build label→index map once; passed into nearestActive each timestep.
    var slm_map = std.AutoHashMap(usize, usize).init(arena);
    for (slm, 0..) |label, i| try slm_map.put(label, i);

    var resting: std.ArrayList(Constraint) = .empty;

    for (timesteps) |active| {
        const intervals = try nearestActive(arena, slm_map, active);

        var gaps: std.ArrayList(Constraint) = .empty;

        for (intervals, 0..) |iv, i| {
            // Skip gate-engaged AODs, only park resting ones
            if (active[i] != null) continue;

            // Unconstrained: no useful bound
            if (iv.left == null and iv.right == null) continue;

            // Slot just after the left boundary atom, or 0 if unbounded.
            // Slot of the right boundary atom itself, or slm.len if unbounded.
            try gaps.append(arena, .{
                .min_slot = if (iv.left) |e| e.c_idx + 1 else 0,
                .max_slot = if (iv.right) |e| e.c_idx else slm.len,
            });
        }

        // Update the resting position with new gaps for each timestep.
        try mergeConstraints(arena, &resting, gaps.items);
    }

    return try resting.toOwnedSlice(arena);
}

// Schedule the moveable qubits: moveable[t][c] holds the AOD qubit sitting at
// slm_slots[c] during timestep t (null = empty column). aod_nodes lists the
// AOD qubits in their rigid left-to-right column order; timesteps[t][k] is
// aod_nodes[k]'s SLM partner at t, or null when it rests.
//
// Active AODs sit at their partner's column. Resting AODs park right to left,
// each in the rightmost free column strictly between its already-placed right
// neighbour and every active AOD to its left - the same right-hugging policy
// placeControlQubits used to reserve the null columns, so a reserved column
// always exists; error.NoRestingSlotAvailable guards that invariant.
pub fn scheduleTargetQubits(
    arena: std.mem.Allocator,
    aod_nodes: []const usize,
    slm_slots: []const ?usize,
    timesteps: []const []const ?usize,
) ![][]?usize {
    var slm_pos = std.AutoHashMap(usize, usize).init(arena);
    for (slm_slots, 0..) |v, c| {
        if (v) |id| try slm_pos.put(id, c);
    }

    const n = aod_nodes.len;
    const moveable = try arena.alloc([]?usize, timesteps.len);

    // Column of aod_nodes[k] this timestep; null = not placed (yet).
    const pos = try arena.alloc(?usize, n);

    // Leftmost admissible column for aod_nodes[k]: strictly right of every
    // active AOD to its left. Resting AODs further left never constrain -
    // they are placed later, bounded to our left by their own right bound.
    const min_col = try arena.alloc(usize, n);

    for (timesteps, 0..) |match, t| {
        const aod_slot = try arena.alloc(?usize, slm_slots.len);
        @memset(aod_slot, null);
        @memset(pos, null);

        // Phase 1: active AODs sit at their SLM partner's column.
        for (match, 0..) |partner, k| {
            const id = partner orelse continue;
            const c = slm_pos.get(id) orelse continue;
            aod_slot[c] = aod_nodes[k];
            pos[k] = c;
        }

        var leftmost: usize = 0;
        for (0..n) |k| {
            min_col[k] = leftmost;
            if (pos[k]) |c| leftmost = @max(leftmost, c + 1);
        }

        // Phase 2: park resting AODs right to left, so each one's right
        // neighbour - active or resting - is already placed and bounds it.
        var k = n;
        while (k > 0) {
            k -= 1;
            if (match[k] != null) continue;

            // The rightmost AOD is unbounded on the right.
            const max_col = if (k + 1 < n) (pos[k + 1] orelse aod_slot.len) else aod_slot.len;

            // Rightmost free column in [min_col[k], max_col): no fixed atom,
            // no AOD placed this timestep.
            var c = max_col;
            var placed = false;
            while (c > min_col[k]) {
                c -= 1;
                if (slm_slots[c] == null and aod_slot[c] == null) {
                    aod_slot[c] = aod_nodes[k];
                    pos[k] = c;
                    placed = true;
                    break;
                }
            }
            if (!placed) {
                trace.print("Failed to place resting AOD {d} at time step {d}\n", .{ aod_nodes[k], t });
                return error.NoRestingSlotAvailable;
            }
        }

        moveable[t] = aod_slot;
    }

    return moveable;
}

// A constraint is an interval of gap slots (slot k sits just left of slm[k],
// slot n after the last atom). The same interval demanded at two different
// timesteps shares one physical slot - the AODs occupy it at different times.
//
// slots:   0   1   2
// acc     [-----]          {0,1}
// new     [-----]          {0,1}
// merged  [-----]          same interval: one shared gap
test "repeated identical constraint merges to one gap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var resting: std.ArrayList(Constraint) = .empty;
    try resting.append(arena, .{ .min_slot = 0, .max_slot = 1 });
    try mergeConstraints(arena, &resting, &.{.{ .min_slot = 0, .max_slot = 1 }});
    try std.testing.expectEqual(@as(usize, 1), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 0, .max_slot = 1 }, resting.items[0]);
}

// Disjoint intervals can never share a physical slot: the new constraint
// survives the sweep as its own gap instead of narrowing the accumulated one.
//
// slots:   0   1   2   3   4   5   6   7   8   9
// acc     [-]
// new                 [-------------------------]
// merged  [-]         [-------------------------]   disjoint: two gaps
test "non-overlapping constraints accumulate to two gaps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var resting: std.ArrayList(Constraint) = .empty;
    try resting.append(arena, .{ .min_slot = 0, .max_slot = 0 });
    try mergeConstraints(arena, &resting, &.{.{ .min_slot = 3, .max_slot = 9 }});
    try std.testing.expectEqual(@as(usize, 2), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 0, .max_slot = 0 }, resting.items[0]);
    try std.testing.expectEqual(Constraint{ .min_slot = 3, .max_slot = 9 }, resting.items[1]);
}

// Partially overlapping intervals share their common slots: the accumulated
// constraint narrows to the intersection and one physical slot serves both
// timesteps. Here the accumulated interval leads (starts further left).
//
// slots:   0   1   2   3   4   5   6   7   8   9
// acc     [---------------------]
// new                 [-------------------------]
// merged              [---------]                   overlap: one narrowed gap
test "overlap with acc leading narrows to the intersection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var resting: std.ArrayList(Constraint) = .empty;
    try resting.append(arena, .{ .min_slot = 0, .max_slot = 5 });
    try mergeConstraints(arena, &resting, &.{.{ .min_slot = 3, .max_slot = 9 }});
    try std.testing.expectEqual(@as(usize, 1), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 3, .max_slot = 5 }, resting.items[0]);
}

// The mirror case: the new interval leads. Intersection is symmetric, so
// the merged gap is the same.
//
// slots:   0   1   2   3   4   5   6   7   8   9
// acc                 [-------------------------]
// new     [---------------------]
// merged              [---------]                   overlap: one narrowed gap
test "overlap with new leading narrows to the intersection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var resting: std.ArrayList(Constraint) = .empty;
    try resting.append(arena, .{ .min_slot = 3, .max_slot = 9 });
    try mergeConstraints(arena, &resting, &.{.{ .min_slot = 0, .max_slot = 5 }});
    try std.testing.expectEqual(@as(usize, 1), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 3, .max_slot = 5 }, resting.items[0]);
}

// Inclusive intervals that touch at a single slot still overlap: the shared
// endpoint is a slot both can use, so the merge narrows to exactly it.
//
// slots:   0   1   2   3   4   5   6   7   8   9
// acc     [-------------]
// new                 [-------------------------]
// merged              [-]                           touch at 3: one gap
test "intervals touching at one slot narrow to it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var resting: std.ArrayList(Constraint) = .empty;
    try resting.append(arena, .{ .min_slot = 0, .max_slot = 3 });
    try mergeConstraints(arena, &resting, &.{.{ .min_slot = 3, .max_slot = 9 }});
    try std.testing.expectEqual(@as(usize, 1), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 3, .max_slot = 3 }, resting.items[0]);
}

// Adjacent intervals share no slot - slot 3 and slot 4 are different
// physical positions - so this is the disjoint case, not an overlap:
// the new constraint stays its own gap.
//
// slots:   0   1   2   3   4   5   6   7   8   9
// acc     [-------------]
// new                     [---------------------]
// merged  [-------------] [---------------------]   adjacent: two gaps
test "adjacent intervals without a shared slot stay two gaps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var resting: std.ArrayList(Constraint) = .empty;
    try resting.append(arena, .{ .min_slot = 0, .max_slot = 3 });
    try mergeConstraints(arena, &resting, &.{.{ .min_slot = 4, .max_slot = 9 }});
    try std.testing.expectEqual(@as(usize, 2), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 0, .max_slot = 3 }, resting.items[0]);
    try std.testing.expectEqual(Constraint{ .min_slot = 4, .max_slot = 9 }, resting.items[1]);
}

// The gap list below is computePositions' merged output for this walk, so
// one can see the generated output format of the gaps. Each gap materializes
// as a null adjacent to its bounding partner.
//
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
// SLM |  ·  |  ·  |  5  |  4  |  2  |  ·  |  6  |  ·  |  ·  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
//  t0 |  1  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |  ·  |  ·  |
//  t1 |  ·  |  1  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |  ·  |
//  t2 |  ·  |  1  |  ·  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |
//  t3 |  ·  |  ·  |  ·  |  ·  |  1  |  3  |  7  |  ·  |  ·  |
//  t4 |  ·  |  ·  |  ·  |  ·  |  ·  |  ·  |  1  |  3  |  7  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
test "placeControlQubits inserts nulls at correct positions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const slm = [_]usize{ 5, 4, 2, 6 };
    const gaps = [_]Constraint{
        .{ .min_slot = 0, .max_slot = 0 },
        .{ .min_slot = 0, .max_slot = 0 },
        .{ .min_slot = 3, .max_slot = 3 },
        .{ .min_slot = 4, .max_slot = 4 },
        .{ .min_slot = 4, .max_slot = 4 },
    };
    const updated = try placeControlQubits(arena, &slm, &gaps);
    const expected = [_]?usize{ null, null, 5, 4, 2, null, 6, null, null };
    try std.testing.expectEqualSlices(?usize, &expected, updated);
}

// Two AODs rest simultaneously between the same atom pair at t0 and t2,
// producing two adjacent null slots in each of those gaps.
//
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
// SLM |  1  |  ·  |  ·  |  2  |  ·  |  3  |  ·  |  ·  |  4  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
//  t0 |  5  |  6  |  7  |  8  |  ·  |  ·  |  ·  |  ·  |  ·  |
//  t1 |  5  |  ·  |  ·  |  6  |  7  |  8  |  ·  |  ·  |  ·  |
//  t2 |  ·  |  ·  |  ·  |  ·  |  ·  |  5  |  6  |  7  |  8  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
test "two adjacent resting slots between each outer atom pair" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const slm = [_]usize{ 1, 2, 3, 4 };
    const t0 = [_]?usize{ 1, null, null, 2 };
    const t1 = [_]?usize{ 1, 2, null, 3 };
    const t2 = [_]?usize{ 3, null, null, 4 };
    const timesteps = [_][]const ?usize{ &t0, &t1, &t2 };
    const gaps = try computePositions(arena, &slm, &timesteps);
    const updated = try placeControlQubits(arena, &slm, gaps);
    const expected = [_]?usize{ 1, null, null, 2, null, 3, null, null, 4 };
    try std.testing.expectEqualSlices(?usize, &expected, updated);
}

// AODs walk left-to-right one step at a time; each step one AOD drops to rest.
// Produces one slot before atom 1, one between 1-2, and two after atom 3.
//
//     +-----+-----+-----+-----+-----+-----+-----+
// SLM |  ·  |  1  |  ·  |  2  |  3  |  ·  |  ·  |
//     +-----+-----+-----+-----+-----+-----+-----+
//  t0 |  4  |  5  |  ·  |  6  |  ·  |  ·  |  ·  |
//  t1 |  ·  |  4  |  5  |  6  |  ·  |  ·  |  ·  |
//  t2 |  ·  |  ·  |  ·  |  4  |  5  |  6  |  ·  |
//  t3 |  ·  |  ·  |  ·  |  ·  |  4  |  5  |  6  |
//     +-----+-----+-----+-----+-----+-----+-----+
test "resting slots spread across three distinct regions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const slm = [_]usize{ 1, 2, 3 };
    const t0 = [_]?usize{ null, 1, 2 };
    const t1 = [_]?usize{ 1, null, 2 };
    const t2 = [_]?usize{ 2, 3, null };
    const t3 = [_]?usize{ 3, null, null };
    const timesteps = [_][]const ?usize{ &t0, &t1, &t2, &t3 };
    const gaps = try computePositions(arena, &slm, &timesteps);
    const updated = try placeControlQubits(arena, &slm, gaps);
    const expected = [_]?usize{ null, 1, null, 2, 3, null, null };
    try std.testing.expectEqualSlices(?usize, &expected, updated);
}

// Broad constraints are progressively narrowed across timesteps. Each merged
// gap parks adjacent to its bounding partner: the two right-bounded gaps land
// left of atom 2, the two left-bounded gaps land right of atom 2.
//
//     +-----+-----+-----+-----+-----+-----+-----+
// SLM |  1  |  ·  |  ·  |  2  |  ·  |  ·  |  3  |
//     +-----+-----+-----+-----+-----+-----+-----+
//  t0 |  ·  |  ·  |  4  |  5  |  ·  |  ·  |  6  |
//  t1 |  4  |  ·  |  ·  |  ·  |  ·  |  5  |  6  |
//  t2 |  4  |  ·  |  5  |  6  |  ·  |  ·  |  ·  |
//  t3 |  ·  |  4  |  5  |  6  |  ·  |  ·  |  ·  |
//  t4 |  ·  |  ·  |  ·  |  4  |  5  |  6  |  ·  |
//     +-----+-----+-----+-----+-----+-----+-----+
test "constraint narrowing parks each slot adjacent to its bounding partner" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const slm = [_]usize{ 1, 2, 3 };
    const t0 = [_]?usize{ null, 2, 3 };
    const t1 = [_]?usize{ 1, null, 3 };
    const t2 = [_]?usize{ 1, null, 2 };
    const t3 = [_]?usize{ null, null, 2 };
    const t4 = [_]?usize{ 2, null, null };
    const timesteps = [_][]const ?usize{ &t0, &t1, &t2, &t3, &t4 };
    const gaps = try computePositions(arena, &slm, &timesteps);
    const updated = try placeControlQubits(arena, &slm, gaps);
    const expected = [_]?usize{ 1, null, null, 2, null, null, 3 };
    try std.testing.expectEqualSlices(?usize, &expected, updated);
}

// Two AODs rest simultaneously between an adjacent active pair at the last
// timestep. The t3 gaps ({5,5} twice) overlap no accumulated gap and must
// survive the sweep as fresh gaps.
//
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+
// SLM |  ·  |  0  |  8  |  2  |  6  |  5  |  ·  |  ·  |  4  |  ·  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+
//  t0 |  1  |  3  |  9  |  7  |  ·  |  ·  |  ·  |  ·  |  ·  |  ·  |
//  t1 |  ·  |  1  |  3  |  ·  |  9  |  7  |  ·  |  ·  |  ·  |  ·  |
//  t2 |  ·  |  ·  |  ·  |  1  |  ·  |  3  |  ·  |  ·  |  9  |  7  |
//  t3 |  ·  |  ·  |  ·  |  ·  |  ·  |  1  |  3  |  9  |  7  |  ·  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+
test "gaps flushed mid-sweep survive as fresh constraints" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const slm = [_]usize{ 0, 8, 2, 6, 5, 4 };
    const t0 = [_]?usize{ null, 0, 8, 2 };
    const t1 = [_]?usize{ 0, 8, 6, 5 };
    const t2 = [_]?usize{ 2, 5, 4, null };
    const t3 = [_]?usize{ 5, null, null, 4 };
    const timesteps = [_][]const ?usize{ &t0, &t1, &t2, &t3 };
    const gaps = try computePositions(arena, &slm, &timesteps);
    const updated = try placeControlQubits(arena, &slm, gaps);
    const expected = [_]?usize{ null, 0, 8, 2, 6, 5, null, null, 4, null };
    try std.testing.expectEqualSlices(?usize, &expected, updated);
}

test {
    std.testing.refAllDecls(@This());
}
