# Next

## Stable resting positions in `logicalSchedule` (Phase 2)

### Background

`logicalSchedule` (`src/route.zig:623-706`) turns the per-timestep active/resting
match into the physical `moveable` grid: Phase 1 places every active AOD at its
SLM partner's column; Phase 2 parks every resting AOD in a free gap column,
recomputed from scratch every timestep via a greedy right-to-left scan
("nearest free gap strictly left of the right neighbour's column").

Phase 2 has no memory across timesteps. An AOD that idles for several
timesteps in a row still gets re-packed into a (possibly different) gap every
single frame, purely as a side effect of its right neighbour's column
shifting. Concretely, with:

```
     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
 SLM |  ·  |  ·  |  5  |  4  |  2  |  ·  |  6  |  ·  |  ·  |
     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
  t0 |  1  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |  ·  |  ·  |
  t1 |  ·  |  1  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |  ·  |
  t2 |  ·  |  1  |  ·  |  3  |  7  |  ·  |  ·  |  ·  |  ·  |
     +-----+-----+-----+-----+-----+-----+-----+-----+-----+
```

AOD `1` hops col0→col1 between t0/t1 even though it doesn't gate until t3 —
nothing requires that move.

This isn't just cosmetic. `schedule.zig`'s `moveAodCompute` (`src/schedule.zig:465-510`)
already skips the load/move/store cycle for a column that hasn't changed
(`if (a.pos.x == dest_x) continue;`, line 475). Every avoidable column change
in `moveable` is a real, physical AOD move (and a store/pickup pair) in the
compiled hardware schedule. Reducing churn in Phase 2's output directly
reduces move count/time on the real device.

### First attempt, and why it's unsafe

Patch tried: thread a `last_pos: []?usize` array (indexed by
`aod.nodes.items` position) through the timestep loop. Phase 2 prefers
`last_pos[i]` over the greedy scan whenever it's still a free, in-bounds gap;
otherwise falls back to the existing scan; `last_pos[i]` is updated wherever
the AOD ends up (Phase 1 or Phase 2).

This fixed the toy example and cut real churn out of the `mvp`/`grid`
snapshots — but `zig build update-snapshots` caught a genuine physical
violation on `grid`:

```
schedule verify: frame 36: qubit 6 moves (50000,52000) -> (80000,52000) through stored qubit 8 at (70000,52000)
error: MoveThroughOccupiedSite
```

Root cause: `verify.zig`'s path-legality check (`src/verify.zig:140-153`)
treats *any* atom that is stored (`trap == .slm`) for the whole frame as an
obstacle for *every other* atom's move that same frame — not just its
immediate ordering neighbour. `last_pos`'s validity check only looked at the
immediate right-neighbour's current column; it had no visibility into some
*other*, unrelated AOD sweeping a long distance straight through the kept
slot that same frame.

The original (unpatched) greedy scan avoids this by accident, not by design:
it repacks every resting AOD to the tightest available slot behind its right
neighbour on *every* frame, so no resting AOD is ever far from the "swept
frontier" — nothing is ever left stranded in a spot a later long sweep needs
to cross. That safety property is exactly what naive stickiness throws away.
Current state: this patch has been reverted; `src/route.zig` is back to the
freshly-fixed (but churny) baseline, all tests green.

### The actual invariant that must hold

For a resting AOD to safely keep column `X` across a span of timesteps, `X`
must not just be a free gap within its immediate neighbour's bound at each of
those timesteps — for *every* frame in that span, `X` must not lie strictly
between the source and destination column of *any* atom (active or resting)
that moves during that frame, regardless of whether that atom is adjacent in
the AOD ordering. That's a cross-atom, per-frame constraint, not a
neighbour-local one.

### Candidate approaches

**A — per-frame path-clearance check (recommended starting point).**
Since `verify.zig` validates path legality one frame at a time, the
constraint can be checked one frame at a time too — no need to reason about
a whole multi-timestep run up front:

1. After Phase 1 places this frame's active AODs, build the set of "movers
   this frame": every AOD (active or resting) whose *previous* placed column
   differs from a proposed *new* column, each carrying a `(from, to)` segment.
   Active AODs' segments are known immediately after Phase 1
   (`last_pos[i] -> aod_slot[c]`).
2. Walk Phase 2 in its existing right-to-left order. For each resting AOD,
   before accepting `last_pos[i]` as this frame's column, check it against
   every active mover's segment computed in step 1: if `last_pos[i]` lies
   strictly between some mover's `from` and `to`, keeping it is unsafe —
   fall back to the scan instead.
3. The scan itself currently only checks that the *destination* gap is free
   (`src/route.zig:687`); it needs the same treatment — a freshly-chosen slot
   must not require sweeping through a column some other AOD is *currently
   stored at* this frame (this covers resting-AOD-vs-resting-AOD collisions:
   an earlier-processed AOD in this same Phase 2 pass that decided to stay
   put is a live obstacle for a later one that's forced to jump past it).
4. Update the "movers this frame" set as Phase 2 assigns each resting AOD's
   slot, so later AODs in the same pass see earlier ones' decisions.

This directly targets the observed failure mode (a long-distance mover
sweeping through an unrelated stationary AOD) and only forces a move when a
real conflict exists in that specific frame, rather than pre-emptively.

**B — run-based interval computation (mirrors `resting.zig`'s Phase 2/3).**
Structurally the same shape as `nearestActive` + `mergeConstraints`
(`src/resting.zig:43-142`), which already solves "one stable slot valid
across many timesteps" for the *fixed* SLM row: split each AOD's timeline
into maximal resting runs, compute the ordering bound `[min,max)` at every
frame in the run and intersect across the run (literally reusing
`mergeConstraints`), then pick one column for the whole run.

The catch: `resting.zig`'s version never had to deal with "someone sweeps
through my slot," because fixed SLM atoms never move — only the ordering
bound mattered there. Reusing it for the *moveable* row still needs the same
path-clearance primitive as approach A, applied to the whole run's frame
range instead of one frame — so B doesn't avoid the hard part, it just
front-loads more of the computation. If a run's interval can't be made safe
for its full span, the run needs to be split and re-solved for the pieces,
which reintroduces per-frame reasoning anyway.

**Recommendation:** implement A first, since it's the minimal safe version of
the fix, is easier to unit test in isolation (one frame at a time, same style
as `resting.zig`'s existing tests), and can be validated incrementally.
Revisit B only if profiling or snapshot review shows A still leaves
significant avoidable churn (e.g. because per-frame conflicts force
unnecessary moves that a full-run view would have avoided by picking a
different column up front).

### Test plan

- Unit tests in `route.zig`, same style as the scenarios already documented
  in `src/resting.zig:222-353`: hand-built `aod`/`fixed`/`timesteps` fixtures
  covering (a) the motivating no-churn case (AOD 1 in the walkthrough above),
  (b) a deliberate long-distance-sweep-over-a-parked-AOD case shaped like the
  `grid` failure, to pin the exact bug this plan is fixing.
- `zig build test`, then `zig build update-snapshots` and review the
  `testdata/` diff by hand — confirm reduced churn (fewer column changes
  between consecutive resting timesteps) without introducing new
  `MoveThroughOccupiedSite`/`AodOrderInversion`/etc. failures.
- `verify.zig`'s replay (already wired into golden tests and
  `update-snapshots`) is the ground truth for physical legality here, not the
  snapshot diff itself — a snapshot can look "reasonable" and still be
  physically illegal, as this exercise showed.
- Consider adding a dedicated small golden case that specifically exercises a
  long resting run *and* a long-distance sweep by an unrelated AOD in the same
  schedule, so this class of bug has permanent regression coverage — the
  existing cases only caught it by chance via `grid`.

### Open questions

- When approach A's fallback scan itself can't find a column that's both a
  free gap *and* clear of every mover's path this frame, what should happen?
  Today's `NoRestingSlotAvailable` return is the honest answer, but confirm
  that's still reachable/meaningful once the scan is path-aware, or whether
  it needs a distinct error.
- Does the incremental "movers this frame" set need to account for AODs that
  become active *later* in the same frame's processing (i.e. does Phase 1's
  active placement ever need to be reconsidered in light of Phase 2's
  path-clearance decisions), or is Phase 1's output always safe to treat as
  fixed background for Phase 2? (Current assumption: yes, fixed — Phase 1 only
  places atoms at their gate partner's column, which is a hard requirement,
  not a scheduling choice.)
