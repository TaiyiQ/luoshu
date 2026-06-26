# Next

## Replace `computeRestingPositions` with `nearestActive`

The O(N) `nearestActive` prototype is working. Wire it in to replace the O(N²)
nested loop in `computeRestingPositions` (route.zig:802-811).

### Bug in current merging (route.zig:876)

```zig
// WRONG — widens the right bound instead of tightening it
const merged = Rest{
    .left  = @max(old_pair.left,  best.left),
    .right = @max(old_pair.right, best.right),  // should be @min
};
```

The intersection of two overlapping intervals `[L1,R1]` and `[L2,R2]` is
`[@max(L1,L2), @min(R1,R2)]`. Fix `.right` to use `@min`.

### Integration notes

- `aod.nodes` is ordered **right-to-left** (`nodes[0]` = rightmost column).
  `nearestActive` treats index 0 as leftmost. When wiring in, either reverse
  the slice or swap left/right in the returned Pair.
- Current code only records resting AODs that have **both** bounds (line 813:
  `if (l != null and r != null)`). Edge AODs with one bound are silently
  dropped. Decide whether to keep that or handle unbounded cases.

### Merging logic (how it should work)

Each physical gap is a fixed null slot in the SLM row. `resting` accumulates
one entry per gap needed, with its position constraint `(left_slm_pos, right_slm_pos)`.

At each new timestep:
- If a new resting interval **overlaps** an existing constraint → same physical
  gap can serve both. Narrow constraint to intersection (`@max(lefts), @min(rights)`).
- If **no overlap** → need a separate new gap.
- AODs resting in the **same timestep** always need distinct gaps.

### Test arrays for `main()`

SLM position mapping used below: qubit 1→pos 0, 2→pos 1, 3→pos 2, 4→pos 3.

```zig
// 1. Same interval both timesteps → 1 gap in [0,3]
const c1_t0 = [_]?usize{ 1, null, 4 };
const c1_t1 = [_]?usize{ 1, null, 4 };

// 2. Overlapping intervals → 1 gap, tighter constraint [1,3]
const c2_t0 = [_]?usize{ 1, null, 4 };
const c2_t1 = [_]?usize{ 2, null, 4 };

// 3. Two resting same timestep → always 2 gaps
const c3_t0 = [_]?usize{ null, null, 4 };

// 4. Count grows then stays: t0=2 resting, t1=1 resting → 2 gaps total
const c4_t0 = [_]?usize{ null, null, 4 };
const c4_t1 = [_]?usize{ 1,    null, 4 };

// 5. Three non-overlapping regions → 3 gaps, no merge possible
const c5_t0 = [_]?usize{ null, 2, null, 4, null };

// 6. Non-overlapping across timesteps → 2 gaps
const c6_t0 = [_]?usize{ 1, 2, null, 4, 4 };
const c6_t1 = [_]?usize{ 1, 1, null, 3, 4 };

// Edge cases
const e_all_active  = [_]?usize{ 1, 2, 3 };          // 0 gaps
const e_all_resting = [_]?usize{ null, null, null };  // unbounded, unresolvable
const e_left_edge   = [_]?usize{ null, 3, 4 };        // right bound only
const e_right_edge  = [_]?usize{ 1, 2, null };        // left bound only
const e_single_act  = [_]?usize{ 3 };
const e_single_rest = [_]?usize{ null };
const e_alternating = [_]?usize{ 1, null, 2, null, 3, null, 4 }; // 3 gaps, no overlap
```
