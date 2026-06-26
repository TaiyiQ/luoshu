# computeRestingPositions — Algorithm Notes

## What it does

This function computes where "resting" AOD atoms should park between quantum gate operations.

- **SLM atoms** — fixed in place, indexed by position in `slm_order`
- **AOD atoms** — movable, slide to pair with SLM atoms to execute gates

Time is divided into timesteps (edge colors). Each timestep, some AOD atoms are "active" (executing a gate), the rest are **resting** (need a parking position).

## Algorithm phases

### Phase 1 — Find active AODs per timestep
Build `active: { aod_node → slm_x_position }` by scanning edges colored with the current timestep.

### Phase 2 — Compute parking intervals for resting AODs
For each resting AOD, find its nearest active left and right neighbors (by AOD array index). The parking slot is:
```
Rest { left: slm_pos_of_left_active, right: slm_pos_of_right_active }
```
The atom must park somewhere between SLM position L and SLM position R.

### Phase 3 — Merge constraints across timesteps
For each old interval (from previous timesteps), find all new intervals (current timestep) that **overlap** it (`new.left < old.right AND old.left < new.right`). Pick the **narrowest** overlapping new interval and replace with the intersection:
```
merged = { left: max(old.left, new.left), right: max(old.right, new.right) }
```
Each timestep progressively tightens the constraint.

### Phase 4 — Extract final positions
Return the `.right` of each final interval as the assigned x-position, sorted ascending.

---

## Closest LeetCode / competitive programming analogues

### Phase 2 — Nearest active neighbors
**Previous/Next Element With Property** (monotonic stack) — LC 739, 496

For each resting AOD at index `i`, the code scans all other AODs to find the nearest active one to the left and right — an O(N²) nested loop. This is the classic "Previous/Next Element With Property" sub-problem, solved in O(N) with a monotonic stack.

**LC 739 (Daily Temperatures)** is the cleanest reference: for each day, find the nearest future day that is warmer. Same structure — scan for nearest neighbor satisfying a predicate on each side.

**LC 84 (Largest Rectangle in Histogram)** is often cited here because it's the canonical hard example of the same monotonic stack pattern, but the thematic connection is weak (histograms vs. atom parking). The overlap is purely algorithmic: LC 84's stack finds nearest-smaller-on-both-sides, which is structurally identical to Phase 2 finding nearest-active-on-both-sides. LC 739 is the more direct reference.

### Phase 3 — Pick narrowest overlapping interval
**Minimum Interval to Include Each Query** — LC 2158

For each query point, find the shortest interval containing it. Here the "point" is replaced by an interval, but the greedy "prefer narrowest" logic is identical. This is the tightest single match to the hardest part of the code.

### Overall structure — Assign slots across time rounds
**Meeting Rooms II** (LC 253) + **Task Scheduler** (LC 621)

Atoms need to be parked in slots defined by their active neighbors across multiple rounds without collision — the same resource-allocation-over-time pattern.

### Best single match
**LC 2158 — Minimum Interval to Include Each Query**

---

## LC 2158 — Detailed mapping to Phase 3

### LC 2158 problem statement

Given a list of intervals and a list of query **points**, for each query find the **smallest interval that contains it**. Return its size, or -1 if none exists.

```
intervals = [[1,4],[2,4],[3,6],[4,4]]
queries   = [2, 3, 4, 5]
answers   = [3, 3, 1, 4]
```

### The mapping

| LC 2158 | Resting positions |
|---|---|
| Query point `q` | Old constraint interval `[old.left, old.right]` |
| Candidate intervals | New timestep intervals `t_resting` |
| Containment: `left <= q <= right` | Overlap: `tp.left < old.right AND old.left < tp.right` |
| Pick smallest containing interval | Pick narrowest overlapping interval |
| Report size | Compute intersection, carry forward |

The core greedy criterion is **identical**: among all valid candidates, prefer the narrowest one. LC 2158 uses this to avoid "wasting" a large interval on a small query. The resting problem uses it to tighten the constraint as much as possible each round.

### Why overlap instead of containment?

In LC 2158 the query is a **point**, so containment is the natural check. Here the "query" is itself an **interval** (the old constraint). Two intervals overlap when:

```
tp.left < old.right  AND  old.left < tp.right
```

Containment (`left <= q <= right`) is just a degenerate case of this where the query interval has zero width.

### Current code vs. LC 2158 solution

The current code is **naive** — O(M × N) nested loop:

```zig
var t_it = t_resting.iterator();
while (t_it.next()) |t_entry| {
    const tp = t_entry.key_ptr.*;
    if (tp.left < old_pair.right and old_pair.left < tp.right) {
        try overlaps.append(gpa, tp);
    }
}
// then scan overlaps for the narrowest
```

The classic LC 2158 solution runs in **O((M + N) log N)**:

1. Sort candidate intervals by size ascending
2. Sort old constraints by left boundary
3. Use a **min-heap** keyed by interval size — push all candidates that could overlap the current constraint, pop until one actually overlaps

The heap gives the narrowest valid candidate immediately without scanning everything.

### The extra step: intersection

LC 2158 stops at "which interval wins." The resting problem goes further — it computes the **intersection** of the old and winning new interval and carries that tighter constraint into the next round:

```zig
const merged = Rest{
    .left  = @max(old_pair.left,  best.left),
    .right = @max(old_pair.right, best.right),  // note: likely should be @min
};
```

Each timestep the valid parking range can only shrink or stay the same.
