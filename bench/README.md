# Benchmarking against NALAC (arXiv:2405.08068)

Compares `gate-compiler` against Table I of *"An Abstract Model and Efficient
Routing for Logical Entangling Gates on Zoned Neutral Atom Architectures"*
(Stade, Schmid, Burgholzer, Wille), the NALAC paper.

## Files

- `arch-fig13.toml` — architecture matching the paper's Figure 13 (entangling
  4×36, storage 12×72, readout 4×72). Timing constants (load/store 20 µs,
  shuttle 0.55 µm/µs, CZ 0.2 µs) live in `src/bench.zig` and already match the
  paper's setup table.
- `generate.py` — pulls the 14 Table I families from MQT Bench 2.2.2 at 20
  qubits, transpiles to `{rx,ry,rz,cz}`, writes `circuits/*.qasm`. Needs a venv
  with `mqt.bench==2.2.2`.
- `compare.py` — runs `gatecomp --bench` on each circuit and tabulates our
  metrics next to the paper's. Stdlib only. Writes `results.md`.
- `circuits/` — generated OpenQASM 3 circuits.

## Reproduce

```sh
python3 -m venv .venv && .venv/bin/pip install "mqt.bench==2.2.2"
.venv/bin/python bench/generate.py     # writes bench/circuits/*.qasm
zig build                              # builds gatecomp
python3 bench/compare.py               # writes bench/results.md
```

## What is and isn't comparable

The paper's timing **constants** and metric **definitions** match ours exactly
(routing overhead = loading + shuttling, in ms; ∥ = avg CZ per Rydberg pulse).
But two things differ by construction:

- **Circuit instances.** The paper used MQT Bench 1.x; we use 2.2.2.
  `portfoliovqe` was removed; `realamprandom/su2random/twolocalrandom` are
  renamed `vqe_*` with different default ansatz repetitions; `qnn` was
  redefined. So `ae`, `qnn`, `realamprandom`, `su2random` have different CZ
  counts than the paper (visible in the table). `dj`, `ghz`, `graphstate`,
  `qft`, `qftentangled`, `qpeexact`, `qpeinexact`, `wstate`, `twolocalrandom`
  match the paper's CZ counts closely.

- **Architecture geometry.** The paper never published exact µm spacings (only
  Figure 13 and a "5 µm" scale bar), so absolute shuttle distances are
  approximate.

### Findings (see `results.md`)

1. **CZ count** reproduces well where the instance matches (qftentangled 429,
   qpeinexact 407, wstate 38, etc.).
2. **Parallelism** matches NALAC closely on structurally-layered circuits
   (graphstate 3.33 vs 3.3; qpeexact 3.67 vs 3.7; dj/ghz 1.0) but is **higher**
   on the QFT family (qft 5.33 vs 1.0; qftentangled 5.43 vs 2.8) because our
   `circuit.decompose` reorders commuting (diagonal) CZ gates into parallel
   stages, which NALAC does not. This advantage is only valid if decompose's
   commutation handling is semantically correct — `verify` checks geometric/site
   validity, not logical equivalence.
3. **Routing overhead** is a consistent ~2–4× the paper's NALAC, because our
   scheduler emits a fuller physical choreography (pickup rides, corridor
   traversals, multi-step Manhattan moves) than NALAC's logical-level model, on
   top of the approximate geometry.
4. **Bug surfaced:** `twolocalrandom` (570 CZ) fails `verify` with
   `SiteConflict` (frame 2143: two atoms on one site) — a real scheduling bug on
   dense circuits, not a parser or benchmark issue.
