# Gate Compiler

Compiles [OpenQASM 3](https://openqasm.com/) circuits into a hardware schedule for a neutral-atom quantum computer - native U/CZ transpilation, qubit routing, and atom-move / pulse scheduling.

## Requirements

- [zig](https://ziglang.org/)
- [just](https://github.com/casey/just)

## Usage

- Quick start leveraging defaults.
```shell
# Build the binary
> just build

# Run the CLI with help options
> ./gatecomp -h

# Run a single circuit and visualize
> ./gatecomp ./ex/mvp/mvp.qasm --viz
```

## Configuration

`cfg/` holds the run configuration:

- `cfg/arch.toml`: the neutral-atom architecture (zones, SLM grids, AOD limits, constraints) — edit it to experiment with different geometries.
- `cfg/assembly.json`: storage occupancy handoff from the atom-rearrangement package — edit it to experiment with different initial placements.

Everything under `cfg/` is user-editable; tests and golden snapshots pin their own copies under `testdata/`, so experiments never break the suite.
- `cfg/settings.toml`: encodes the CLI flags (`[options]`), so a plain `gatecomp <circuit>.qasm` needs none. Command-line flags always win over settings values.

## Benchmark

Passing several circuits runs them as a suite: the visualizer stays closed, each
circuit writes `<out>/<name>-schedule.json` and `<name>-bench.json` when the
`out` directory is set, and a schedule-quality table prints:

```shell
> ./gatecomp ex/graph/*.qasm

circuit                   qubits  frames           cz    colors  cz/pulse  shuttle_us  loading_us  total_us  compile_ms
-----------------------------------------------------------------------------------------------------------------------
ex/graph/graph-10-9.qasm      10     105        15/15       6/6      2.50      2141.8       900.0    3043.0        3.28
ex/graph/graph-50-5.qasm      50     247        75/75      12/6      6.25     10360.0      2360.0   12722.4       21.23
ex/graph/graph-50-9.qasm      50     209        75/75      11/5      6.82      9581.8      2100.0   11684.0       18.02
ex/graph/graph-60-5.qasm      60     280        90/90      12/5      7.50     13473.6      2560.0   16036.0       21.28
ex/graph/graph-90-9.qasm      90     392      135/135      13/6     10.38     23352.7      3520.0   26875.3       47.93
-----------------------------------------------------------------------------------------------------------------------
5 circuits                                    390/390     54/28               58910.0     11440.0   70360.8      111.74
```

The suite table measures the quality of the compiled schedules; `bench.sh`
(`just bench <suite> <ref>`) measures the compiler instead — an A/B of compile
time and peak memory between the working tree and a baseline commit.
