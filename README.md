<p align="center">
  <img src="doc/logo.svg" alt="Neutral Atom Gate Compiler" width="600">
</p>

# Gate Compiler

Compiles [OpenQASM 3](https://openqasm.com/) circuits into a hardware schedule for a neutral-atom quantum computer. Native gate transpilation, qubit routing, and atom-move / pulse scheduling.

## Requirements

- [zig](https://ziglang.org/): `>= 0.16.0`
- [just](https://github.com/casey/just) (optional): Every recipe maps to a plain `zig build` command
- [jq](https://jqlang.org/) (optional): Only for the `script/bench-*.sh` AB benchmarks

## Usage

- Quick start leveraging defaults.
```shell
# Build the binary (or: zig build && cp zig-out/bin/gatecomp .)
> just build

# Run the CLI with help options
> ./gatecomp -h

# Run a single circuit and visualize
> ./gatecomp ./ex/mvp/mvp.qasm --viz
```

For an in-depth understanding, see [CLI](./doc/cli.md).

## Configuration

`cfg/` holds the run configuration:

- `cfg/arch.toml`: The neutral-atom architecture (zones, SLM grids, AOD limits, constraints).
    - Edit it to experiment with different geometries.
- `cfg/assembly.json`: Storage occupancy handoff from the atom-rearrangement package.
    - Edit it to experiment with different initial placements.
- `cfg/settings.toml`: Encodes the input options (`[options]`: `arch`, `assembly`, `out`) for `--cfg`.

Everything under `cfg/` is user-editable; tests and golden snapshots pin their own copies under `testdata/`, so experiments never break the suite.

Inputs come from flags or from a config file, never both:

```shell
# Flag Mode:
# Specify inputs on the command line
> ./gatecomp circuit.qasm --arch cfg/arch.toml --out zig-out

# Config Mode:
# Reference a settings TOML instead
> ./gatecomp circuit.qasm --cfg cfg/settings.toml
```

Mixing `--cfg` with `--arch`, `--asm`, or `--out` is an error. The runtime toggles `--viz` and `-v/--verbose` are CLI-only and work in either mode. With neither flags nor `--cfg`, the built-in defaults apply.

## Benchmark

Passing several circuits runs them as a suite: the visualizer stays closed, each circuit writes [Schedule](./doc/schedule.md) and [Benchmark](./doc/benchmark.md) when the `out` directory is set, and a schedule-quality table prints:

```shell
> ./gatecomp ex/graph/*.qasm --out zig-out

circuit                   qubits  frames           cz    colors  cz/pulse  shuttle_ms     load_ms  route_ms  compile_ms
-----------------------------------------------------------------------------------------------------------------------
ex/graph/graph-10-9.qasm      10      94        15/15       6/6      2.50         1.7         0.5       2.2        0.19
ex/graph/graph-50-5.qasm      50     190        75/75      12/6      6.25        10.0         0.9      10.9        0.35
ex/graph/graph-50-9.qasm      50     154        75/75      11/5      6.82         9.1         0.7       9.8        0.26
ex/graph/graph-60-5.qasm      60     218        90/90      12/5      7.50        12.9         1.0      13.9        0.38
ex/graph/graph-90-9.qasm      90     305      135/135      13/6     10.38        21.9         1.5      23.4        1.21
-----------------------------------------------------------------------------------------------------------------------
5 circuits                                    390/390     54/28                  55.6         4.6      60.2        2.38
```

## Testing

`just test` (or `zig build test --summary all`) runs the suite. Compiler output is compared byte-for-byte against golden snapshots in `testdata/`, so an intentional output change fails the suite until the goldens are regenerated with `just update` — review the resulting `testdata/` diff as part of the change.

## License

This project is released under the MIT License - see [LICENSE](LICENSE).
