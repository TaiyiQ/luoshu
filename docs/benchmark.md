# Benchmark metrics (`--bench`)

`gatecomp <circuit.qasm> --bench <path>` writes one JSON object summarizing
the compiled schedule. It follows the evaluation methodology of NALAC (Stade
et al., arXiv:2405.08068): the cost of a zoned neutral-atom schedule is
dominated by *routing overhead* — loading/storing atoms into the AOD and
shuttling them between zones — not by the gate pulses themselves. Produced by
`bench.measure` (`src/bench.zig`) and serialized by `serialize.benchToJson`
(`src/serialize.zig`).

The schedule already encodes parallelism: every op in one hardware frame
executes simultaneously (the AOD translates all its atoms at once, the
Rydberg laser fires one global pulse), so a frame's wall-clock cost is

```
max(move distance in frame) / shuttle_speed
  + (load_us  if the frame picks atoms up)
  + (store_us if the frame drops atoms)
  + (rydberg_us if the frame fires an entangling pulse)
```

and the schedule's runtime is the sum over frames. A naive serialized router
produces many more frames for the same circuit, so these metrics reward the
parallelism the compiler achieves.

## Annotated example

```jsonc
{
  "num_qubits": 20,   // qubits declared in the circuit

  "frames": 58,       // schedule depth: number of parallel hardware frames
                      // (timesteps). Wall-clock time is the sum of each
                      // frame's cost, so fewer frames means better packing.

  "ops": {
    "load": 60,       // AOD pick-ups: an atom lifted from a trap into a
                      // moving tweezer
    "store": 60,      // AOD drop-offs: an atom placed back into a trap
    "move": 290,      // AOD translations (shuttles); one op per atom moved
    "rydberg": 1,      // entangling laser pulses fired (a single pulse can
                      // entangle several CZ pairs at once)
    "raman": 60,       // single-qubit gate pulses applied
    "measure": 1       // readout ops
  },

  "entangling": {
    "pulses": 1,             // same as ops.rydberg
    "cz_pairs": 10,          // total CZ gates executed, summed across all
                            // pulses
    "avg_cz_per_pulse": 10.000
                            // cz_pairs / pulses: the parallelism NALAC
                            // reports. A fully serialized router scores
                            // 1.0; here all 10 CZ pairs fired in a single
                            // pulse, so this circuit scores 10.0
  },

  "distance_nm": {
    "total": 8443000.0,   // sum of every move op's shuttle distance
                          // (serial view, i.e. as if moves happened one
                          // after another), in nanometers
    "max": 153000.0       // the single longest shuttle among all move ops,
                          // in nanometers
  },

  "time_us": {
    // wall-clock breakdown (microseconds), derived from timing_model below
    "loading": 560.000,     // pick-up + drop time, summed once per frame
                            // that has a load/store (not once per atom,
                            // since the AOD moves all its atoms together)
    "shuttling": 1516.364,  // per-frame slowest-atom transit time
                            // (frame's max move distance / shuttle speed),
                            // summed over frames
    "routing": 2076.364,    // loading + shuttling — NALAC's headline
                            // routing-overhead cost
    "gate": 0.200,          // entangling + single-qubit pulse time (time
                            // actually firing lasers)
    "total": 2076.564       // routing + gate — modeled end-to-end
                            // schedule runtime
  },

  "timing_model": {
    // physical constants used to compute time_us, so results are
    // reproducible/comparable across runs. Defaults are NALAC's (§V);
    // override via bench.Timing to model a different platform
    "shuttle_nm_per_us": 550.000, // AOD transport speed
    "load_us": 20.000,            // AOD pick-up time (trap ramp-on)
    "store_us": 20.000,           // SLM drop time (trap hand-off)
    "rydberg_us": 0.200,          // duration of one entangling (CZ) pulse
    "raman_us": 0.000             // duration of one single-qubit pulse;
                                  // defaults to 0 since NALAC doesn't
                                  // model 1Q gate time — ops.raman is
                                  // still counted for reference
  },

  "compile_ns": 1725250
  // wall-clock nanoseconds gatecomp itself spent producing this schedule
  // (compiler.compile() only) — not a hardware time. null if not measured.
}
```
