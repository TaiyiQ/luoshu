const std = @import("std");

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

// Phase 2 — for each resting AOD in active[], find the nearest active (gate-engaged)
// AOD to its left and right using a monotonic stack (LC 739 pattern).
// slm maps qubit label → SLM array index so each boundary is recorded as an Entangle.
fn nearestActive(
    gpa: std.mem.Allocator,
    slm: std.AutoHashMap(usize, usize),
    active: []const ?usize,
) ![]Interval {
    const n = active.len;
    const result = try gpa.alloc(Interval, n);
    @memset(result, .{});

    var last_active: ?Entangle = null;
    var stack: std.ArrayList(usize) = .empty; // indices of resting AODs awaiting a right boundary
    defer stack.deinit(gpa);

    for (active, 0..) |label, j| {
        if (label) |id| {
            // Active AOD found: resolve all resting AODs that were waiting for a right boundary.
            const e = Entangle{ .c_idx = slm.get(id).?, .t_idx = j };
            while (stack.pop()) |i| result[i].right = e;
            last_active = e;
        } else {
            // Resting AOD: record the most recent active AOD as its left boundary.
            result[j].left = last_active;
            try stack.append(gpa, j);
        }
    }

    return result;
}

fn sortedCopy(gpa: std.mem.Allocator, items: []const Constraint) ![]Constraint {
    const copy = try gpa.dupe(Constraint, items);
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

// Phase 3 — LC 1851 offline sweep.
//
// Each accumulated gap is a constraint that must be satisfied across all past timesteps.
// Each new_list entry is a constraint from the current timestep.
// A new constraint that overlaps an accumulated one means the same physical gap slot can
// serve both — narrow the accumulated constraint to the intersection.
// A new constraint with no overlap requires a fresh gap slot.
//
// Sort both sides by min_slot. Sweep accumulated gaps left to right; for each gap G:
//   push every new C with min_slot(C) <= max_slot(G)  — C starts before G ends, could overlap,
//   lazily discard heap top where max_slot(C) < min_slot(G) — C ended before G started,
//   pop the narrowest remaining C as the match (consumed — one physical slot per AOD).
// Leftover new constraints become additional gaps in the accumulator.
// Merges gaps from the current timestep into resting in place.
fn mergeConstraints(
    gpa: std.mem.Allocator,
    resting: *std.ArrayList(Constraint),
    gaps: []const Constraint,
) !void {
    const sorted_rest = try sortedCopy(gpa, resting.items);
    defer gpa.free(sorted_rest);

    const sorted_gaps = try sortedCopy(gpa, gaps);
    defer gpa.free(sorted_gaps);

    var heap: Heap = .empty;
    defer heap.deinit(gpa);

    var result: std.ArrayList(Constraint) = .empty;
    errdefer result.deinit(gpa);

    var i: usize = 0;
    for (sorted_rest) |slot| {
        while (i < sorted_gaps.len and sorted_gaps[i].min_slot <= slot.max_slot) : (i += 1) {
            try heap.push(gpa, sorted_gaps[i]);
        }
        while (heap.peek()) |top| {
            if (top.max_slot < slot.min_slot) _ = heap.pop() else break;
        }
        if (heap.pop()) |best| {
            try result.append(gpa, slot.intersect(best));
        } else {
            try result.append(gpa, slot);
        }
    }

    // Gaps pushed to the heap but never matched: no resting constraint covered them.
    while (heap.pop()) |c| try result.append(gpa, c);

    // Gaps never pushed: their min_slot was beyond every resting constraint's max_slot.
    while (i < sorted_gaps.len) : (i += 1) try result.append(gpa, sorted_gaps[i]);

    resting.deinit(gpa);
    resting.* = result;
}

// Place one null slot per gap into the SLM array at each gap's leftmost valid position (min_slot).
pub fn updateSlm(
    gpa: std.mem.Allocator,
    slm: []const usize,
    gaps: []const Constraint,
) ![]?usize {
    const n = slm.len;

    // n atoms create n+1 gap slots: one before each atom plus one after the last.
    // nulls[i] = number of null slots to insert before slm[i]; nulls[n] = after slm[n-1].
    const nulls = try gpa.alloc(usize, n + 1);
    @memset(nulls, 0);
    defer gpa.free(nulls);

    // Each gap parks at its leftmost valid slot; tally how many land at each slot index.
    for (gaps) |gap| nulls[gap.min_slot] += 1;

    var result: std.ArrayList(?usize) = .empty;
    errdefer result.deinit(gpa);

    // Insert the nulls parked at slot i (before slm[i]), then the atom itself.
    for (0..n) |i| {
        for (0..nulls[i]) |_| try result.append(gpa, null);
        try result.append(gpa, slm[i]);
    }

    // Slot n sits after the last atom; flush any nulls parked there.
    for (0..nulls[n]) |_| try result.append(gpa, null);

    return result.toOwnedSlice(gpa);
}

// Runs Phase 2 (nearestActive) and Phase 3 (mergeConstraints) across all timesteps,
// accumulating the set of gap constraints that must hold simultaneously.
pub fn computeRestPositions(
    gpa: std.mem.Allocator,
    slm: []const usize,
    timesteps: []const []const ?usize,
) ![]Constraint {
    // Build label→index map once; passed into nearestActive each timestep.
    var slm_map = std.AutoHashMap(usize, usize).init(gpa);
    defer slm_map.deinit();
    for (slm, 0..) |label, i| try slm_map.put(label, i);

    var resting: std.ArrayList(Constraint) = .empty;
    defer resting.deinit(gpa);

    for (timesteps, 0..) |active, t| {
        std.debug.print("t{}\n", .{t});

        const intervals = try nearestActive(gpa, slm_map, active);
        defer gpa.free(intervals);

        var gaps: std.ArrayList(Constraint) = .empty;
        defer gaps.deinit(gpa);

        for (intervals, 0..) |iv, i| {
            // Skip gate-engaged AODs, only park resting ones
            if (active[i] != null) continue;

            // Unconstrained: no useful bound
            if (iv.left == null and iv.right == null) continue;

            // Slot just after the left boundary atom, or 0 if unbounded.
            // Slot of the right boundary atom itself, or slm.len if unbounded.
            try gaps.append(gpa, .{
                .min_slot = if (iv.left) |e| e.c_idx + 1 else 0,
                .max_slot = if (iv.right) |e| e.c_idx else slm.len,
            });
        }

        // Update the resting position with new gaps for each timestep.
        try mergeConstraints(gpa, &resting, gaps.items);
    }

    return try resting.toOwnedSlice(gpa);
}

//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
// SLM |  ·  |  ·  |  5  |  4  |  2  |  ·  |  6  |  ·  |  ·  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
//  t0 |  1  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |  ·  |  ·  |
//  t1 |  ·  |  1  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |  ·  |
//  t2 |  ·  |  1  |  ·  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |
//  t3 |  ·  |  ·  |  ·  |  ·  |  1  |  3  |  7  |  ·  |  ·  |
//  t4 |  ·  |  ·  |  ·  |  ·  |  ·  |  ·  |  1  |  3  |  7  |
//     +-----+-----+-----+-----+-----+-----+-----+-----+-----+

test "repeated identical constraint merges to one gap" {
    const gpa = std.testing.allocator;
    var resting: std.ArrayList(Constraint) = .empty;
    defer resting.deinit(gpa);
    try resting.append(gpa, .{ .min_slot = 0, .max_slot = 1 });
    try mergeConstraints(gpa, &resting, &.{.{ .min_slot = 0, .max_slot = 1 }});
    try std.testing.expectEqual(@as(usize, 1), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 0, .max_slot = 1 }, resting.items[0]);
}

test "non-overlapping constraints accumulate to two gaps" {
    const gpa = std.testing.allocator;
    var resting: std.ArrayList(Constraint) = .empty;
    defer resting.deinit(gpa);
    try resting.append(gpa, .{ .min_slot = 0, .max_slot = 0 });
    try mergeConstraints(gpa, &resting, &.{.{ .min_slot = 3, .max_slot = 9 }});
    try std.testing.expectEqual(@as(usize, 2), resting.items.len);
    try std.testing.expectEqual(Constraint{ .min_slot = 0, .max_slot = 0 }, resting.items[0]);
    try std.testing.expectEqual(Constraint{ .min_slot = 3, .max_slot = 9 }, resting.items[1]);
}

test "updateSlm inserts nulls at correct positions" {
    const gpa = std.testing.allocator;
    const slm = [_]usize{ 5, 4, 2, 6 };
    // slm has 4 atoms → 5 gap slots (0..4)
    // {null,0} → min=0, max=0;  {2,3} → min=3, max=3;  {3,null} → min=4, max=4
    const gaps = [_]Constraint{
        .{ .min_slot = 0, .max_slot = 0 },
        .{ .min_slot = 0, .max_slot = 0 },
        .{ .min_slot = 3, .max_slot = 3 },
        .{ .min_slot = 4, .max_slot = 4 },
        .{ .min_slot = 4, .max_slot = 4 },
    };
    const updated = try updateSlm(gpa, &slm, &gaps);
    defer gpa.free(updated);
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
    const gpa = std.testing.allocator;
    const slm = [_]usize{ 1, 2, 3, 4 };
    //const aod = [_]usize{ 5, 6, 7, 8 };
    const t0 = [_]?usize{ 1, null, null, 2 };
    const t1 = [_]?usize{ 1, 2, null, 3 };
    const t2 = [_]?usize{ 3, null, null, 4 };
    const timesteps = [_][]const ?usize{ &t0, &t1, &t2 };
    const gaps = try computeRestPositions(gpa, &slm, &timesteps);
    defer gpa.free(gaps);
    const updated = try updateSlm(gpa, &slm, gaps);
    defer gpa.free(updated);
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
    const gpa = std.testing.allocator;
    const slm = [_]usize{ 1, 2, 3 };
    //const aod = [_]usize{ 4, 5, 6 };
    const t0 = [_]?usize{ null, 1, 2 };
    const t1 = [_]?usize{ 1, null, 2 };
    const t2 = [_]?usize{ 2, 3, null };
    const t3 = [_]?usize{ 3, null, null };
    const timesteps = [_][]const ?usize{ &t0, &t1, &t2, &t3 };
    const gaps = try computeRestPositions(gpa, &slm, &timesteps);
    defer gpa.free(gaps);
    const updated = try updateSlm(gpa, &slm, gaps);
    defer gpa.free(updated);
    const expected = [_]?usize{ null, 1, null, 2, 3, null, null };
    try std.testing.expectEqualSlices(?usize, &expected, updated);
}

// Broad constraints are progressively narrowed across timesteps, converging to
// one slot before atom 1, one between 1-2, and two adjacent slots between 2-3.
//
//     +-----+-----+-----+-----+-----+-----+-----+
// SLM |  ·  |  1  |  ·  |  2  |  ·  |  ·  |  3  |
//     +-----+-----+-----+-----+-----+-----+-----+
//  t0 |  4  |  ·  |  ·  |  5  |  ·  |  ·  |  6  |
//  t1 |  ·  |  4  |  5  |  ·  |  ·  |  ·  |  6  |
//  t2 |  ·  |  4  |  5  |  6  |  ·  |  ·  |  ·  |
//  t3 |  4  |  ·  |  5  |  6  |  ·  |  ·  |  ·  |
//  t4 |  ·  |  ·  |  ·  |  4  |  5  |  6  |  ·  |
//     +-----+-----+-----+-----+-----+-----+-----+
test "constraint narrowing produces one slot before and two adjacent at end" {
    const gpa = std.testing.allocator;
    const slm = [_]usize{ 1, 2, 3 };
    //const aod = [_]usize{ 4, 5, 6 };
    const t0 = [_]?usize{ null, 2, 3 };
    const t1 = [_]?usize{ 1, null, 3 };
    const t2 = [_]?usize{ 1, null, 2 };
    const t3 = [_]?usize{ null, null, 2 };
    const t4 = [_]?usize{ 2, null, null };
    const timesteps = [_][]const ?usize{ &t0, &t1, &t2, &t3, &t4 };
    const gaps = try computeRestPositions(gpa, &slm, &timesteps);
    defer gpa.free(gaps);
    const updated = try updateSlm(gpa, &slm, gaps);
    defer gpa.free(updated);
    const expected = [_]?usize{ null, 1, null, 2, null, null, 3 };
    try std.testing.expectEqualSlices(?usize, &expected, updated);
}
