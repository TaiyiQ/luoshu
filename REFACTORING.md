# Refactoring Roadmap

A prioritized review of the gate compiler, written from a compiler-engineering
standpoint. The framing throughout: this is a compiler with four IRs —

```
QASM text ──parse──▶ Circuit ──decompose──▶ Stages ──route──▶ Sequence ──schedule──▶ Frames (Hardware)
            circuit.zig         circuit.zig        route.zig            schedule.zig
```

Most of what follows is about making those boundaries real, making the output
*verifiable*, and making regressions impossible to miss.

---

## P0 — Correctness and completeness

### 1. The compiler never entangles or measures

`Rydberg` and `Measure` ops exist in the op union (`schedule.zig`), `draw.zig`
can render them, `serialize.zig` can emit them — but **no code path ever emits
either**. The whole point of shuttling atoms into the compute zone is the
Rydberg pulse, and it never fires. The output JSON is a movement schedule, not
a quantum program.

- After `moveSlmCompute` + `moveAodCompute` place a stage's atoms, emit
  `.rydberg = .{ .zone = .compute }` (one per AOD timeframe / color, since
  conflicting CZs are serialized by the edge coloring).
- At end of `Pipeline.compile`, emit `.measure` for all qubits (readout zone
  routing can come later; measuring in storage is a fine first step).

This is the highest-value change in the repo: it turns the artifact from an
animation into a compilation.

### 2. Add a schedule verifier pass (`verify.zig`)

There is no legality checking anywhere. The frames representation makes a
verifier cheap to write and precise to specify. Check, per frame and across
frames:

- **Trap-state machine per qubit**: `load` only when in SLM, `move`/`store`
  only when in AOD, exactly one terminal state at end. (The 17/17 load/store
  balance we observed was verified by hand — it should be a pass.)
- **Site exclusivity**: no two atoms occupy the same position at the end of a
  frame.
- **Path legality**: AOD moves must not sweep through occupied trap sites
  (this is what the half-sep lane choreography is *for* — verify it).
- **AOD rigidity**: atoms moved in the same frame must preserve relative x/y
  order (AOD rows/columns cannot cross each other).
- **Blockade**: during a `rydberg` frame, only intended pairs sit within
  `constraints.db_nm` of each other.

Run it in debug builds after `Pipeline.compile`, and in every test. A routing
bug that today shows up as a visual glitch in the animation becomes a failing
assertion with a frame number.

> **Status (2026-06-11):** implemented in `verify.zig`; runs in every golden
> test, in `update-snapshots`, and after `Pipeline.compile` in debug builds.
> It immediately found a real routing bug: the grid circuit's logical schedule
> swaps AOD qubits 2 and 6 between colors 2 and 3 (`AodOrderInversion`,
> frame 30) — two AOD columns cannot cross. The edge coloring's order
> constraints don't cover this case. Tracked as `known_violation` on the grid
> golden case; the test flips when the routing fix lands.

### 3. The hardware config is loaded but not obeyed

`cfg.aod` (max rows/cols, `min_sep_nm`) and `cfg.constraints` (blockade
radius, zone gap, fidelities) are parsed, converted, printed — and **never
consulted by scheduling**. Pickup can exceed AOD column capacity; nothing
checks `min_sep_nm` between AOD-held atoms. Either the scheduler respects
these or the verifier rejects schedules that violate them — preferably both.

Also validate the config itself in `arch.load`: `compute_zone.slms.len >= 2`
(`grid(1)` is indexed unconditionally), `sep_nm > 0`, zones non-overlapping,
`num_qubits <= sites`. Today a malformed TOML produces an index-out-of-bounds
panic deep in scheduling instead of a config error at load time.

> **Status (2026-06-11):** done. `arch.validate` (run by `arch.load`) rejects
> malformed configs at load time: fewer than 2 compute SLMs, zero-sized trap
> grids or separations, SLM grids extending outside their zone, zones
> overlapping or closer than `dz_nm`, broken blockade geometry (`dr < db < dw`),
> out-of-range fidelities. The verifier enforces `cfg.aod` per frame: row and
> column capacity (`AodCapacityExceeded`) and `min_sep_nm` between AOD rows
> and columns (`AodSeparationViolation`). The scheduler also respects the
> limits directly: `pickup` rejects registers wider than the AOD, and
> `Hardware.init` rejects circuits with more qubits than loading-window sites
> (`TooManyQubits`). Giving the config teeth exposed that `example/arch.toml`
> was itself illegal three ways: the storage zone's 300um box swallowed the
> compute and readout zones, the compute SLM grids (74um tall) poked out of
> their 70um zone, and `min_sep_um = 4` is unsatisfiable by the half-sep lane
> choreography over a 3um storage grid — the example is now self-consistent
> (`min_sep_um = 1.5`). Making the *scheduler* min-sep-aware (so coarser AODs
> can pick up adjacent atoms in multiple passes) remains future work. Goldens
> unchanged byte-for-byte.

### 4. The QASM parser fails without locations and skips silently

- Unknown statements/gates fall through to `skipToSemicolon()` with no
  diagnostic — an unsupported gate silently disappears from the circuit.
  A compiler must never silently drop semantics: error out, or at minimum
  collect a diagnostic list the driver prints.
- Errors are bare `error.ParseError` with no line/column. Track offset → 
  line/col in the parser and return a diagnostic struct. Cheap to add now,
  painful to retrofit later.

---

## P1 — Testing and infrastructure

### 5. Tests exist but cannot run

`route.zig` has six snapshot tests; there is **no `zig build test` step**, no
`snapshots/` directory, and no `update-snapshots` step (the error message in
`snapshot.zig` references one). Consequence: `serialize.zig` and
`snapshot.zig` have silently bit-rotted twice already this month — lazy
analysis means dead code doesn't even get compiled.

- Add `zig build test` (route module tests; schedule/arch unit tests).
- Add `zig build update-snapshots` to regenerate goldens.
- Add a `comptime { std.testing.refAllDeclsRecursive(@This()); }` test per
  module so *everything* at least compiles even when unreferenced.

### 6. Golden-test the IR boundaries

The JSON serializers now produce deterministic, time-sorted output — that's a
golden-testing gift. For a handful of circuits (`bell`, `ghz-3`, `grid`,
`qft-5`):

- golden `Sequence` JSON (logical routing output), and
- golden `Hardware` JSON (physical schedule),

checked byte-for-byte. Any change to MIS/coloring/choreography becomes a
visible, reviewable diff instead of a subtle animation change. This is the
standard regression net for compiler pipelines and it costs an afternoon.

> **Status (2026-06-12):** implemented in `golden.zig` (six cases, plus
> qasm-driven cases through `circuit.load` and an assembly-handoff case).
> One hard-won lesson now on record: goldens pin *stability*, not
> *correctness* — they defend whatever output was blessed, and the verifier
> cannot help because it checks hardware legality, never equivalence with
> the source circuit. Proof: `decompose` had a staging bug (the CZ branch
> read both qubits' stages but never advanced them, so a U following a CZ
> on a lagging qubit was hoisted *before* it — a different unitary). The
> bug sat inside the blessed `ghz-3` and `qft-5` goldens, where every
> golden run re-confirmed it; all six circuits were too symmetric to make
> it visible as anything but bytes. It fell out of writing contract-level
> unit tests for `decompose`'s ordering invariant ("no gate stages before
> a preceding gate on a shared qubit" — `circuit.zig`). Moral: every IR
> boundary needs its contract tested directly; snapshots only guard
> against *unintended change*, unit tests against *being wrong*.

---

## P1 — Architecture and layering

### 7. The front-end drives the back-end

`circuit.zig` (front-end IR + parser) imports `schedule`, `route`, **and
raylib** (the `rl` import is currently dead but still forces the dependency
in `build.zig`). `Pipeline.compile` — a front-end type — orchestrates the
entire back-end. Inverting this cleans the whole graph:

- Move the stage-loop orchestration out of `circuit.Pipeline.compile` into a
  driver (`compiler.zig` or `main.zig`): *for each stage: route → schedule*.
- `circuit.zig` then depends on nothing but `std` (drop `schedule`, `route`,
  `arch`, `raylib` imports). It is pure front-end: parse + decompose.
- Dependency graph becomes a DAG that mirrors the pass pipeline:
  `arch ← schedule ← driver → route → circuit` instead of today's tangle.

> **Status (2026-06-11):** done. The stage loop lives in `compiler.zig`
> (`compile` + `routeStage`); `circuit.zig` is pure front-end depending only
> on `std` (the dead `rl` import and the raylib/raygui module wiring are
> gone). `schedule.raman` now takes its own `RamanGate` type instead of
> `circuit.U`, and `route.zig`'s dead `schedule` import is dropped, so the
> module graph is exactly the DAG above. Goldens unchanged byte-for-byte.

### 8. Passes print to stderr unconditionally

`route.zig` has 57 `std.debug.print` calls; `sequence.print()` is called
unconditionally inside `Pipeline.compile`. Two sites are gated behind
`enabled = builtin.mode == .Debug`; the rest always fire. A compiler's
library code should be silent by default.

- Introduce one tracing facility (even just `route.trace(fmt, args)` gated by
  a flag or scope enum), or hoist all printing into the driver behind `-v`.
- This also unblocks using the compiler as a library / in tests without
  stderr noise.

> **Status (2026-06-11):** done. `trace.zig` is the one tracing facility: a
> runtime `trace.enabled` flag (set by the driver from `-v`) plus
> `trace.print`. All of route's pass tracing and `compiler.compile`'s
> `sequence.print()` go through it, replacing the compile-mode
> (`builtin.mode == .Debug and !builtin.is_test`) gating — so a Debug build
> of the CLI is now silent by default too. Error diagnostics that accompany
> a returned error (verifier `vfail`, config `cfail`, snapshot mismatches,
> route's `NoRestingSlotAvailable`) intentionally stay on `std.debug.print`.

### 9. Name the IRs and unify the vocabulary

The same concept currently has three names: `Sequence.fixed` /
`"slm_slots"` / "SLM qubits"; `moveable` / `"aod_slots_per_color"` /
"timeframes" / "colors"; `Frame` / "timestep" / `t`. Pick one term per
concept, rename, and put a six-line glossary at the top of `route.zig`.
Cheap, and it pays rent every time someone (including you in three months)
reads the routing code.

---

## P2 — Hygiene and mechanical cleanups

### 10. Arena-allocate the schedule

`Hardware.deinit` walks every frame switching on op kind to free
`raman.targets` / `measure.qubits`. `Sequence` already uses an arena —
`Hardware` should too: one arena for frames + payloads, `deinit` = one
`arena.deinit()`. Removes a whole class of leak bugs as op payloads grow
(and they will: rydberg pair lists, measure results).

> **Status (2026-06-11):** done. `Hardware` carries an arena that owns
> frames, op payloads, `placement`, and `initial`; `deinit` is one
> `arena.deinit()`. `gpa` stays for construction scratch (work lists,
> occupancy sets), which is still freed eagerly.

### 11. Unify qubit id types

`usize` in route/circuit, `u32` in ops, `@intCast` sprinkled at every
boundary. Pick `u32` (or a `Qubit = u32` newtype) end-to-end; the casts
disappear and the signatures document themselves.

> **Status (2026-06-11):** done for the qubit-id domain: `circuit.U` /
> `circuit.Cz` and the gate builder methods are `u32`, matching the ops —
> the boundary casts in the driver are gone and the remaining `@intCast`s
> sit at the QASM parse boundary and loop-index → id conversions. Route's
> graph nodes and `Sequence` slot tables deliberately stay `usize`: they are
> array indices throughout, `u32` ids coerce into them losslessly where the
> layers meet, and converting them would add casts rather than remove any.

### 12. Split `draw.zig`'s view-model from its render loop

1377 lines mixing per-frame precomputation (`frame_positions`,
`frame_loaded` — pure functions of the schedule) with raylib calls. Extract
the precompute into a `ViewModel.init(gpa, hw)` — it becomes unit-testable
(e.g., "loaded state is monotone between load/store") and the render loop
shrinks to pure drawing.

> **Status (2026-06-11):** done. `viewmodel.zig` (no raylib dependency)
> computes per-frame positions, loaded flags, `num_qubits`, and the op
> `Summary` in one schedule walk; it runs in `zig build test` with exactly
> the suggested tests. `draw.physical` consumes the view-model and is pure
> rendering.

### 13. CLI arguments

`main.zig` hardcodes `../qasm/mvp.qasm` + `./example/arch.toml` with
commented alternates — the recent path breakage came directly from this.
`gatecomp <circuit.qasm> [--arch <file>] [--emit-json <path>] [--draw]`
removes the edit-recompile loop and the comment graveyard, and makes the
golden tests in §6 trivial to script.

> **Status (2026-06-11):** done. `gatecomp <circuit.qasm> [--arch <file>]
> [--emit-json <path>] [--draw] [-v|--verbose] [-h|--help]` — drawing is now
> opt-in, JSON emission goes wherever you point it, and `-v` flips the §8
> trace flag. Bad usage and unloadable files exit 1 with a one-line
> diagnostic instead of an error trace. `just run [circuit]` keeps the old
> draw-the-example behavior.

### 14. Misc

- Delete the dead `rl` import in `circuit.zig` (covered by §7, but do it
  regardless).
- `Op.t` is now redundant with frame index; once consumers stop reading it,
  drop the field (`emit` is the only writer, so this is mechanical).
- `pickup`'s `siteOccupied` is O(atoms) per check inside a loop — fine today,
  but an occupancy hash set per frame falls out of the verifier work (§2)
  for free.

> **Status (2026-06-11):** all done. The `rl` import went with §7. `Op` is
> gone entirely — a `Frame` is a list of `OpKind` and the frame index is the
> timestep; serializers print `t` from the index (goldens unchanged) and the
> verifier dropped its now-meaningless stamp check. `pickup` keeps a
> `Point`-keyed occupancy set (atoms leave it when picked up; unpicked atoms
> never move during pickup, so the set stays exact) instead of scanning the
> placement per probe.

---

## Suggested order

| # | Item | Why first |
|---|------|-----------|
| 1 | §5 test step + §6 goldens | Everything after this is protected by a net |
| 2 | §1 rydberg/measure emission | Turns the tool into a compiler |
| 3 | §2 verifier | Locks in correctness of all past and future choreography |
| 4 | §7 layering inversion | Makes the pass structure explicit before more passes land |
| 5 | §3 config validation/obedience | Verifier gives it teeth |
| 6 | §8 tracing, §13 CLI | Quality of life, unblocks scripting |
| 7 | P2 items | Opportunistic, alongside other work |
