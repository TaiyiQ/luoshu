# Benchmark metrics

`luoshu <circuit.qasm> --out <dir>` writes `<dir>/<name>-bench.json`: one JSON object summarizing the compiled schedule.

## Example

From `ex/mqt/ae_20.qasm`:

```jsonc
{
  "num_qubits": 20,   // qubits declared in the circuit

  "frames": 3011,     // schedule depth: number of parallel hardware frames
                      // (timesteps). Wall-clock time is the sum of each
                      // frame's cost, so fewer frames means better packing.

  "ops": {
    "load": 1539,     // AOD pick-ups: an atom lifted from a trap into a
                      // moving tweezer
    "store": 1539,    // AOD drop-offs: an atom placed back into a trap
    "move": 6450,     // atoms moved, counted per atom. (The schedule JSON
                      // groups simultaneous same-axis moves into one op per
                      // AOD translation; this counter stays per-atom.)
    "rydberg": 108,   // entangling laser pulses fired (a single pulse can
                      // entangle several CZ pairs at once)
    "raman": 402,     // single-qubit gate pulses applied
    "measure": 1,     // readout ops
    "reset": 0        // readout-zone repump-to-|0> ops
  },

  "entangling": {
    "pulses": 108,           // same as ops.rydberg
    "cz_pairs": 380,         // total CZ gates executed, summed across all
                            // pulses
    "avg_cz_per_pulse": 3.519
                            // cz_pairs / pulses: the parallelism NALAC
                            // reports. A fully serialized router scores
                            // 1.0; here 380 CZ pairs shared 108 pulses
  },

  "distance_nm": {
    "total": 81393000.0,  // sum of every atom's shuttle distance (serial
                          // view, i.e. as if moves happened one after
                          // another), in nanometers
    "max": 142000.0       // the single longest shuttle among all moves,
                          // in nanometers
  },

  "time_us": {
    // wall-clock breakdown (microseconds), derived from timing_model below
    "loading": 28100.000,   // pick-up + drop time, summed once per frame
                            // that has a load/store (not once per atom,
                            // since the AOD moves all its atoms together)
    "shuttling": 47744.545, // per-frame slowest-atom transit time
                            // (frame's max move distance / shuttle speed),
                            // summed over frames
    "routing": 75844.545,   // loading + shuttling — NALAC's headline
                            // routing-overhead cost
    "gate": 21.600,         // entangling + single-qubit pulse time (time
                            // actually firing lasers)
    "total": 75866.145      // routing + gate — modeled end-to-end
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
    "raman_us": 0.000,            // duration of one single-qubit pulse;
                                  // defaults to 0 since NALAC doesn't
                                  // model 1Q gate time — ops.raman is
                                  // still counted for reference
    "reset_us": 0.000             // duration of one reset repump; 0 for
                                  // the same reason
  },

  // wall-clock nanoseconds luoshu itself spent producing this schedule
  "compile_ns": 251648625
}
```
