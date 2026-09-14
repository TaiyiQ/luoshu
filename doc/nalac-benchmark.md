# Benchmark report: luoshu vs NALAC

*2026-09-04 · luoshu `8dd70a6` · MQT QMAP `9583c1a` · MQT Bench 1.1.9, 20-qubit circuits*

This report compares luoshu against **NALAC**, the zoned neutral-atom compiler from MQT QMAP - [arXiv:2405.08068](https://arxiv.org/abs/2405.08068). Both compilers are evaluated on the same circuits, the same architecture family, and the same timing model.

## Executive Summary

Across the twelve MQT Bench 20-qubit circuits the pinned NALAC build can compile, luoshu:

- Achieves **12.8% higher entangling-gate parallelism**, with identical CZ pair counts on every circuit.
- Routes **43.4% faster** (×1.77), winning **all 12 of 12** circuits;
- Spends **24× less compiler wall-clock** producing those schedules (geometric mean; 6.2 ms vs 138 ms for the whole suite).

## Benchmark Setup

### NALAC Driver
MQT QMAP pinned at commit `9583c1a`, `na::nalac` with `MaximizeParallelismHeuristic` - the configuration the paper evaluates.

### Circuits
The benchmark family from the NALAC paper's evaluation, regenerated from **MQT Bench pinned at 1.1.9**. Circuits are qiskit-transpiled to the local basis {`rz`, `ry`, `rx`, `cz`} at optimization level 0 and fed identically to both compilers.

### Architecture
The paper's fixture, taken from MQT QMAP's own test suite (`test_namapper.cpp`): 

- Storage `12x72` sites at `5×5 um`
- Entangling `4×36` at `10×12 um`
- readout `4×72` at `5 um` pitch
- `~20 µm` inter-zone gaps.

NALAC runs on its native JSON fixture; luoshu runs on an `arch.toml` audited coordinate-for-coordinate against that fixture.

One asymmetry is geometric and documented below:

- NALAC fixture stacks: entangling | storage | readout (readout adjacent to storage),
- Luoshu's zone model stacks: storage | compute | readout, so our readout trip additionally crosses the compute zone.

### Timing Methodology

All microsecond figures in this report come from replaying each compiler's emitted schedule under the paper's architecture parameters:

- AOD shuttle speed **0.55 um/us**, distances Euclidean per move group.
- **20 us** per load and per store, charged once per frame containing one.
- **0.2 us** per entangling pulse.
- each frame billed at its slowest atom's transit.

This is exactly the model `bench.zig` applies to luoshu's own schedules (see [benchmark.md](./benchmark.md)); NALAC's LOAD/MOVE/STORE stream is replayed under the same constants.

## Benchmark Results

Parallelism is CZ pairs per entangling pulse (higher is better); route time is loading + shuttling in milliseconds, readout-adjusted per the methodology above (lower is better). CZ pair counts are pairwise identical.

| Circuit | CZ Pairs | Parallel NALAC | Parallel Ours | Route NALAC | Route Ours | Speedup |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| ae | 380 | 2.73 | **3.52** | 94.6 | **44.7** | ×2.12 |
| dj | 19 | 1.00 | 1.00 | 1.7 | **1.0** | ×1.71 |
| ghz | 19 | 1.00 | 1.00 | 13.4 | **7.9** | ×1.70 |
| graphstate | 20 | 5.00 | 5.00 | 2.5 | **2.4** | ×1.04 |
| qft | 410 | 3.73 | **5.33** | 75.8 | **35.1** | ×2.16 |
| qftentangled | 429 | 3.83 | **5.43** | 79.2 | **36.2** | ×2.19 |
| qnn | 779 | — | 4.67 | — | 52.6 | — |
| qpeexact | 407 | 2.87 | **3.67** | 80.4 | **47.1** | ×1.71 |
| qpeinexact | 407 | 2.87 | **3.67** | 81.0 | **47.1** | ×1.72 |
| realamprandom | 570 | 1.22 | 1.22 | 57.6 | **34.9** | ×1.65 |
| su2random | 570 | 1.22 | 1.22 | 57.5 | **34.9** | ×1.65 |
| twolocalrandom | 570 | 1.22 | 1.22 | 57.6 | **34.9** | ×1.65 |
| wstate | 38 | 1.00 | 1.00 | 16.5 | **7.2** | ×2.29 |

Geometric means over the 12 NALAC-feasible circuits (`qnn` excluded):

| Metric | Ratio | Reading |
| :--- | ---: | :--- |
| parallelism (ours / NALAC) | ×1.128 | +12.8% more CZ pairs per pulse |
| routing speedup, raw (NALAC / ours) | ×1.652 | ours 39.5% faster |
| routing speedup, readout-adjusted | ×1.766 | ours 43.4% faster |

## Compiler Wall-Clock

Everything above prices the *schedules*; this section compares the time the compilers themselves take to produce them. Both sides were measured on the same machine from optimized builds (luoshu `zig build -Doptimize=ReleaseFast`; NALAC the Release CMake build of the pinned tree).

Luoshu's number times `compiler.compile()` - routing plus scheduling, excluding QASM parsing and output serialization - while NALAC's is the mapper's own reported wall-clock, excluding its harness's circuit construction.

| Circuit | NALAC ms | Luoshu ms | Speedup |
| :--- | ---: | ---: | ---: |
| ae | 19.83 | 0.70 | ×28 |
| dj | 0.55 | 0.06 | ×10 |
| ghz | 3.86 | 0.09 | ×43 |
| graphstate | 0.69 | 0.04 | ×18 |
| qft | 18.59 | 0.51 | ×37 |
| qftentangled | 18.80 | 0.53 | ×35 |
| qnn | — (fails) | 0.72 | — |
| qpeexact | 17.70 | 0.61 | ×29 |
| qpeinexact | 18.61 | 0.53 | ×35 |
| realamprandom | 11.72 | 0.84 | ×14 |
| su2random | 11.78 | 0.79 | ×15 |
| twolocalrandom | 11.63 | 0.71 | ×16 |
| wstate | 4.30 | 0.10 | ×41 |

Geometric-mean speedup **×24** over the 12 comparable circuits; the whole suite compiles in 6.2 ms against NALAC's 138 ms.

Both compilers are fast in absolute terms, but sub-millisecond compilation leaves headroom for the compile-in-the-loop uses (parameter sweeps, calibration-conditioned recompilation) that tens of milliseconds start to strain.

## Reproduction

Luoshu side, from this repository at `8dd70a6` or later:

```shell
zig build
./luoshu ex/mqt/ae_20.qasm --out zig-out # writes ae_20-bench.json
```

The metrics schema, including every timing constant used here, is documented in [benchmark.md](./benchmark.md); the schedule format in [schedule.md](./schedule.md). Pinned upstream inputs: MQT Bench `1.1.9`, MQT QMAP `9583c1a`, timing constants from arXiv:2405.08068 §V (0.55 µm/µs, 20 µs load/store, 0.2 µs CZ).
