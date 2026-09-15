# ADR 001: Move-abstracted IR between circuit and schedule

- **Status:** Proposed
- **Date:** 2026-07-03

## Context

The compiler currently translates OpenQASM 3 circuits end-to-end into a hardware schedule (per-atom `load`/`move`/`store`/`rydberg`/`raman` ops). All routing and placement decisions - which qubits move, in what order, where they rest - are made internally by the compiler passes.

At the current maturity of neutral-atom compilation, human scheduling insight often beats heuristics, but the only ways to inject it today are (a) rewriting the input circuit or (b) patching compiler internals. There is no stable interface in between.

The literature offers no representation at the altitude we need:

- **ZAIR** (ZAC, HPCA'25, [arXiv:2411.11784](https://arxiv.org/abs/2411.11784)) is a zoned-architecture IR, but it is compiler-internal and site-explicit - qubits are located by `(qubit, array, row, col)` tuples. ZAC also infers qubit *reuse* (keeping atoms in the entanglement zone) automatically.
- The **MQT abstract model** ([arXiv:2405.08068](https://arxiv.org/abs/2405.08068)) formalizes load/store/move at the schedule level, for automated routing, not for human authorship.
- **Bloqade shuttle/lanes** (QuEra, on Kirin) lets users author movement, but at trap-position/trajectory level — below our target altitude.
- End-to-end compilers (ZAP, Enola, Atomique, PowerMove, DasAtom) expose no human-facing layer at all.

The gap: a representation that is *user-authorable*, *geometry-free*, *move-abstracted*, and *order-explicit* - the user owns the execution strategy, the compiler owns the physical realization.

## Decision

Introduce an IR between the logical (circuit) stage and the physical (schedule) stage with the following design.

### State model

Every qubit is in exactly one of three locations:

| Location | Structure | Persists |
|---|---|---|
| `storage zone` sites         | unordered pool (`assembly.json`) | across program |
| `compute zone` control sites | totally ordered sequence         | across runs    |
| `compute zone` target sites  | totally ordered sequence         | between `pick` and its `drop` |

The three orders are the *entire* logical machine state. No coordinates, site indices, or trajectories appear in the IR.

### Instructions

Three executable instructions plus one declaration:

```
place q…                  // declaration/assertion of the control-row order
pick  q…                  // left-to-right row order
cz    [control,target]…   // one movement step + one global Rydberg pulse
drop  q… <zone>           // current zone to destination zone
```

- **`place`**: Storage zone to compute zone transfer instruction. Defined the order of the control qubits in the compute zone.
- **`pick`**: Order is immutable for the row's lifetime (no-cross).
- **`cz`**: Pairs on one line are simultaneous; consecutive lines are strictly ordered. Batching is *explicit* - the compiler never merges or splits lines. Pair syntax is `[control, target]`: first element is always the placed SLM atom, second always the picked AOD atom.
- **`drop`**: Move atoms from the current zone to the defined zone.

### Division of Labor

| Decision | Owner |
|---|---|
| Who moves, who stays static, in what order | user (IR) |
| Which pairs interact, per pulse, and pulse sequencing | user (IR) |
| Which atoms stay in `computing` across runs (reuse) | user (IR) |
| Actual SLM sites, gap spacing, resting columns | compiler |
| AOD trajectories, no-cross/collision realization | compiler |
| Staging positions at pick time | compiler |

### Naming and Syntax

- Instruction verbs are **`pick`/`drop`**, *not* `load`/`store`: the schedule output already uses `"op": "load"`/`"op": "store"` (see `src/serialize.zig`, `src/schedule.zig`), the mapping is not 1:1 (one `pick` of n qubits expands to n schedule `load`s plus moves). Sharing verbs across adjacent layers invites exactly the level confusion the IR exists to prevent.
- Logical pairs use **brackets** `[1,0]`; parentheses stay reserved for physical coordinates `(x, y)` in schedule/trace output.

### Example

```
place  0 8 2 6 5 4              // control qubit order. Can only be fixed in compute zone.
pick   1 3 9 7
cz     [1,0] [3,8] [9,6] [7,5]
cz     [1,2] [3,5] [9,4]        // 7 rests
cz     [1,5] [7,4]              // 3, 9 rest
drop   9 7 storage              // 1, 3 are kept in the CZ for next run

fixed  0 1 8 2 3 4  // checkpoint
pick   6 5          // last run's targets become movers
cz     [6,1] [5,3]
drop   6 5 measure  // send to measurement zone
```

## Rejected Alternatives

- **Site-explicit IR (ZAIR-style `(array, row, col)` tuples).** Binds programs to one architecture instance and drags the user into geometry - the part the compiler is better at.
- **Trajectory-level user control (bloqade-shuttle style).** Rejected for same reason, one level lower.
- **`load`/`store` as IR verbs.** Rejected for the naming-collision reasons above, despite the attractive register-file analogy.

## Consequences

### Motivation

- Program legality is decidable at the IR level, independent of the compiler - order violations become type-error-like diagnostics.
- Deterministic: the same IR yields the same schedule structure (debuggable, reproducible, benchmarkable).
- Fixing the order turns joint scheduling + routing into routing-only.
- Qubit reuse across runs is expressible (and auditable) rather than inferred.
- The IR is also a *target*: an automated optimizer can emit it, making it a compiler-to-compiler interface, not only a human one.

### Risks

- Schedule quality is bounded by the ordering the user writes - garbage in, garbage out. This sensitivity is deliberate: it is the lever the IR exists to expose.
- Site assignment becomes a whole-program problem for the compiler. Anchored drops and resting movers require gap lookahead across runs.
- Expressiveness is deliberately cut to keep legality trivially checkable: only one AOD row is live at a time, `cz` always pairs a mover with a placed atom, and a row must fully disband before the next `pick`.

## Open Questions

- Multiple named AOD rows (`pick r0 = …`) once hardware/scheduling needs them.
- Single-qubit (`U`, `Rx`, `Ry`, `Rz`) and measurement instructions in the IR, or keep those at the circuit level.
- Partial picks into a live row (physically plausible at row ends; currently disallowed for simpler ordering rules).

## References

- ZAC / ZAIR: [arXiv:2411.11784](https://arxiv.org/abs/2411.11784),
  [HPCA'25 PDF](https://vast.cs.ucla.edu/sites/default/files/publications/HPCA25_ZAC-2.pdf)
- MQT abstract model / NALAC: [arXiv:2405.08068](https://arxiv.org/abs/2405.08068),
  [TUM CDA neutral atoms](https://www.cda.cit.tum.de/research/quantum/na/)
- Routing-aware placement: [arXiv:2505.22715](https://arxiv.org/pdf/2505.22715)
- ZAP: [arXiv:2411.14037](https://arxiv.org/abs/2411.14037)
- Bloqade stack: [blog](https://www.quera.com/blog-posts/programming-neutral-atoms-inside-bloqades-new-software-stack),
  [bloqade-lanes](https://github.com/QuEraComputing/bloqade-lanes),
  [Kirin](https://queracomputing.github.io/kirin/latest/blog/2025/02/28/introducing-kirin-a-new-open-source-software-development-tool-for-fault-tolerant-quantum-computing/)
