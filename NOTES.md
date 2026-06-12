# Gate Compiler — Implementation Notes

**Paper:** *An Abstract Model and Efficient Routing for Logical Entangling Gates on Zoned Neutral Atom Architectures*  
Stade, Schmid, Burgholzer, Wille — TU Munich, 2024  
https://arxiv.org/abs/2405.08068

---

## What this compiler does

Takes an OpenQASM 3 circuit and produces a physical execution schedule for a **zoned neutral atom architecture** (three zones: storage, entangling/compute, readout). The architecture uses:
- **SLM traps** — static, fixed positions
- **AOD traps** — dynamically adjustable 2D optical lattice; atoms in the same row/column move together

The key constraint is that entangling (CZ) gates can only run in the compute zone. Qubits must be shuttled there, gates applied via a global Rydberg beam, then shuttled back.

The paper's algorithm maximises gate parallelism within a single "run" (load → sweep → unload) by assigning qubits to SLM or AOD based on a maximal independent set of the interaction graph, then using edge-colouring to determine the time step for each CZ gate.

---

## Module map

```
src/
  main.zig       — top-level driver: load circuit → compile → physical schedule → visualise
  circuit.zig    — OpenQASM 3 parser; Circuit type; decompose() into alternating layers
  graph.zig      — undirected/directed adjacency-list graph with per-edge integer colouring
  route.zig      — logical routing: MIS, DSatur edge colouring, SLM ordering, logical schedule
  schedule.zig   — physical schedule: storage placement, move ops, Raman ops, Rydberg ops
  architecture.zig       — architecture config types; TOML loader (µm → nm conversion)
  viz.zig        — Raylib interactive visualiser
  snapshot.zig   — snapshot test harness (needs repair — see Remaining Work)
  debug.zig      — debug printing helpers
```

Output files written to `zig-out/`:
- `logical_0.json`, `logical_1.json`, … — one per entangling layer
- `physical.json` — full physical op sequence

---

## Pipeline

```
QASM file
    │
    ▼  circuit.QasmParser
Circuit  (flat list of Native gates: U, CZ)
    │
    ▼  circuit.decompose()
Decomposition  (alternating single_qubit / entangling layers)
    │
    ├─ pre_raman = first single_qubit layer (if any)
    │
    └─ for each entangling layer i:
           │
           ▼  core.Graph.init + addEdge
         interaction graph  (nodes = qubits, edges = CZ pairs for this layer)
           │
           ▼  route.compile()
         schedule.Logical  {slm_slots, aod_slots_per_color}
           │
           └─ post_run_ramans[i] = single_qubit layer at i+1 (if any)
    │
    ▼  schedule.physical()
Physical  {ops[], placement[], slots[]}
    │
    ▼  viz.simulate()
Raylib window
```

---

## route.compile() — the core algorithm (§V of paper)

### 1. Maximal Independent Set  (`maxIndependentSet`)
- Nodes sorted by degree descending; ties broken by index descending.
- Greedy: add node if no already-selected neighbour.
- **Isolated nodes (degree 0) are skipped** — they have no CZ gates in this layer and cause downstream panics in `slmGraph` if included.
- AOD qubits = nodes in MIS.  SLM qubits = everything else (that has degree > 0).

### 2. Edge colouring  (`colorEdges` + `leastAdmissible`)
Modified DSatur (Algorithm 1 in paper):
- Iterate over AOD nodes in degree-descending order.
- For each AOD node, sort its SLM edges by (saturation desc, degree desc) and assign the *least admissible colour*.
- **Least admissible colour** = smallest integer that is:
  - different from all adjacent edge colours (standard DSatur), AND
  - greater than any colour of an adjacent edge that does *not* share the same AOD endpoint (AOD order-preservation — prevents AOD crossings).
- A cycle-detection constraint graph (`AodConstraints`) is maintained incrementally; colours that would create ordering cycles are rejected.

### 3. SLM column ordering  (`slmGraph` + `topoSort`)
- For each AOD qubit, its SLM neighbours' colours define a total order (left → right = ascending colour).
- Combine all AOD-induced orders into a directed "dependency graph" on SLM qubits.
- Topological sort gives the global left-to-right SLM column order.

### 4. Resting positions  (`computeRestingPositions` + `placeSlmWithResting`)
- At each time step, some AOD qubits are "resting" (not interacting); they must sit in gaps between SLM qubits outside any blockade radius.
- `computeRestingPositions` accumulates how many extra gaps are needed between each consecutive pair of SLM qubits across all time steps.
- `placeSlmWithResting` inserts `null` slots into `slm_slots` at the required positions.

### 5. Logical schedule  (`logicalSchedule`)
- Returns `aod_slots_per_color[t][col]`: which AOD qubit is in which column at each time step.
- Phase 1: active AOD qubits placed at their SLM partner's column.
- Phase 2: resting AOD qubits placed right-to-left into the nearest free null slot, maintaining strict left-to-right ordering.

---

## schedule.physical() — physical schedule generation (§V-E of paper)

Physical time steps per run:

```
t=0       pre-Raman          Individually addressed Raman pulses; atoms in storage.
          (skipped if no ops)
──── per entangling layer ──────────────────────────────────────────────────────────────
t=T       SLM bulk move       All SLM qubits: storage → compute zone (y-axis AOD).
t=T+1     AOD sweep step 0    AOD qubits move to column 0 SLM partner; Rydberg fires.
t=T+2     AOD sweep step 1    AOD qubits move to column 1 SLM partner; Rydberg fires.
...
t=T+N     AOD sweep step N    (N = max_color from edge colouring)
t=T+N+1   Move-back           All involved qubits: compute → storage (y-axis AOD).
t=T+N+2   post-run Raman      Single-qubit layer following this CZ layer.
          (skipped if no ops)
────────────────────────────────────────────────────────────────────────────────────────
```

Key notes on `qubitPlacement`:
- Called once, based on the first run's SLM/AOD ordering.
- SLM qubits placed first (topo-sort order), then AOD qubits, then any remaining.
- Uses `storage_placement` as the invariant target for all move-back ops across all runs.

---

## What's implemented

| Paper section | Component | File | Status |
|---|---|---|---|
| §II | OpenQASM 3 parser (r, h, x, y, z, rx, ry, rz, u, cz, cx, sx) | circuit.zig | ✅ |
| §IV | Circuit decomposition into alternating layers | circuit.zig | ✅ |
| Fig. 6 | Multi-layer compilation loop (one `route.compile` per entangling layer) | main.zig | ✅ |
| §V-B | MIS (greedy, degree-sorted, isolated nodes excluded) | route.zig | ✅ |
| §V-C | Modified DSatur + AOD order-preservation + cycle detection | route.zig | ✅ |
| §V-D | SLM partial order → topo sort | route.zig | ✅ |
| §V-D | Resting positions computation + slot placement | route.zig | ✅ |
| §V-D | Logical schedule (AOD column assignments per time step) | route.zig | ✅ |
| §V-E | SLM bulk move storage → compute | schedule.zig | ✅ |
| §V-E | AOD x-sweep + Rydberg pulses | schedule.zig | ✅ |
| §V-E | Move-back-to-storage after each run | schedule.zig | ✅ |
| — | Pre-Raman, intermediate Raman, post-run Raman | schedule.zig | ✅ |
| — | Architecture config (TOML, µm→nm) | architecture.zig | ✅ |
| — | Raylib visualiser | viz.zig | ✅ |
| — | JSON output (logical + physical) | schedule.zig | ✅ |

---

## Remaining work

### 1. Test infrastructure  *(medium effort — prerequisite for items 2 and 3)*

`snapshot.zig` references `route.Graph` and `route.Schedule` — types that no longer exist. The file won't compile. `testdata/` doesn't exist. `build.zig` has no `zig build test` step.

**To do:**
- Fix `snapshot.zig`: replace `route.Graph` → `core.Graph`, `route.Schedule` → `schedule.Logical`, update `scheduleToJson` to call `schedule.Logical.toJson`.
- Add `zig build test` step to `build.zig` with the route module and all its deps wired up.
- Create `src/testdata/` and generate the five passing snapshots (mvp, cycle, ladder, ghz, qft) by running tests once in update mode.

---

### 2. Grid topology bug in `computeRestingPositions`  *(medium effort)*

`test "snapshot: 3x3 grid"` is explicitly marked TODO. The 3×3 grid has MIS = {0, 2, 4, 6, 8} (5 AOD) and SLM = {1, 3, 5, 7} (4 SLM). At several time steps, 3–4 AOD qubits are simultaneously resting, which is the maximum pressure case for the interval-merging logic in `computeRestingPositions`.

The interval-merging loop (route.zig:567–632) accumulates `(left, right)` pairs across time steps to determine how many extra null slots to insert between each SLM pair. For dense topologies this merge likely produces wrong counts, causing `logicalSchedule` to fail with `error.NoRestingSlotAvailable`.

Requires item 1 (test infra) to isolate.

---

### 3. Demand-driven storage placement  *(significant effort — §V-E)*

Current: all storage positions are assigned once from the first run's SLM/AOD split (`qubitPlacement`). For subsequent runs, the "SLM qubits" for that run may be in different storage rows, making the single y-axis `moveSlmQubits` op physically invalid — atoms in different rows can't be moved in one AOD operation.

The paper (§V-E) specifies:
- **Loading:** find free storage slots in the *same row*, in the *correct column order* (matching topo-sort order for the compute zone). Qubits with positions from a previous run reuse them.
- **Unloading:** after each run, find the minimal number of storage rows that fit all returning qubits and fill their free slots.

For the current test circuits (≤ 10 qubits, all fitting in one storage row) this is masked. It matters for circuits with more qubits than `arch.storage_zone.slm.num_col`.

---

### 4. AOD capacity constraint check  *(small effort)*

No validation that `aod.nodes.items.len ≤ arch.aod.max_num_col`. If the MIS exceeds hardware capacity, the schedule is silently invalid. Should error out with a message after `maxIndependentSet`.

---

### 5. Logical qubit array translation  *(large effort — §III-D)*

The paper targets FTQC where each "logical qubit" is an array of physical atoms (e.g., 7 atoms in a 2×4 grid for the Steane code). After computing the logical routing schedule, every qubit ID should be replaced by its array, with the upper-left atom as the reference. The array size comes from a separate "configuration" input (code parameters). Not implemented; currently the compiler works at individual-qubit granularity only.

---

## Bugs fixed during this session

| File | Bug | Fix |
|---|---|---|
| route.zig | `countSaturation` used `w != v` (always true — no self-loops) instead of `w != u` in the "Edges from v" loop. Caused saturation counts to over-report, distorting DSatur sort order and potentially using more colours (time steps) than necessary. | `w != v` → `w != u` |
| route.zig | `maxIndependentSet` included isolated (degree-0) nodes in the MIS. These have no CZ gates and caused an integer underflow panic in `slmGraph` when the per-layer graph has qubits not involved in that layer. | Skip nodes with `g.degree[v] == 0` before the greedy loop. |
| schedule.zig | `moveAodQubits` labelled compute→compute AOD x-sweep moves as `Axis.y` (vertical). The sweep is horizontal. | `Axis.y` → `Axis.x` |
| main.zig | `entanglingGraph` collapsed all CZ layers into one flat graph, silently deduplicating repeated qubit pairs and ignoring layer ordering. | Replaced with per-layer loop: one `core.Graph` + `route.compile` per entangling layer. |
| schedule.zig | `qubitPlacement` used `sz.slm.num_col * sz.slm.num_row` as the qubit count, wrong for circuits with fewer qubits than storage capacity. | Added explicit `n` parameter; fall-through assigns remaining qubits to any leftover slots. |
