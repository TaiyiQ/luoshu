# Gate Compiler

Compiles [OpenQASM 3](https://openqasm.com/) circuits into a hardware schedule for a neutral-atom quantum computer — native U/CZ transpilation, qubit routing, and atom-move / pulse scheduling.

## Requirements

- [zig](https://ziglang.org/) ≥ 0.16 (dependencies are fetched by `zig build`)
- [just](https://github.com/casey/just) — optional, mostly for developers.

## Usage

- Pull example [qasm](https://github.com/TaiyiQ/qasm) circuits next to this repo. For example:
```shell
> cd
├── gate-compiler
│   ...
├── qasm
│   ...
```

- Check the CLI help output.
```
> zig build run -- --help

usage: gatecomp [circuit.qasm] [options]

Compiles one circuit when <circuit.qasm> is given; without it, runs
every circuit in the settings [benchmark] list (visualization off,
per-circuit outputs under the benchmark out_dir).

options:
  --config <file>     settings TOML encoding these options
                      (default: ./config/settings.toml, may be absent)
  --arch <file>       architecture TOML (default: ./config/arch.toml)
  --asm <file>        storage occupancy JSON from the upstream
                      atom-rearrangement package; omitting it uses
                      procedural placement
  --out <path>        write the hardware schedule as JSON
  --bench <path>      write schedule benchmark metrics as JSON
  --no-draw           skip the schedule visualization
  -v, --verbose       trace the compiler passes to stderr
  -h, --help          show this help
```

- Quick start leveraging defaults.

```shell
zig build run -- ../qasm/mvp.qasm
```

- Explicit arguments and default overrides.

```shell
zig build run -- ../qasm/mvp.qasm --arch config/arch.toml --asm config/assembly.json --out schedule.json
```

## Configuration

`config/` holds the run configuration:

- `config/arch.toml` — the neutral-atom architecture (zones, SLM grids, AOD limits, constraints).
- `config/assembly.json` — storage occupancy handoff from the atom-rearrangement package.
- `config/settings.toml` — encodes the CLI arguments (`[options]`), so a bare `gatecomp` needs no flags. Command-line flags always win over settings values.

`[benchmark]` in `settings.toml` lists circuits to compile when no `<circuit.qasm>` is given:

```shell
> zig build run

gatecomp: example/bell-state/bell.qasm: 2 qubits, 30 frames, schedule 1025.7us, compile 0.95ms
gatecomp: example/ex1/mvp.qasm: 8 qubits, 72 frames, schedule 2186.7us, compile 0.99ms
...
```

Each circuit writes `<out_dir>/<name>.hardware.json` and `<out_dir>/<name>.bench.json`.

## Visualizer

`--draw` (on by default) opens a set of windows in sequence - close each to advance:

1. The OpenQASM parsed **circuit** (`U`, `CZ`, reset `R`).
2. The same circuit decomposed into **stages**.
3. The compiled schedule animated on the input **architecture**.

| View             | Control                | Action                          |
| ---------------- | ---------------------- | ------------------------------- |
| Circuit          | mouse wheel, `j` / `k` | scroll                          |
| Schedule         | `space`                | play / pause                    |
| Schedule         | `k` / `j`              | step forward / back (hold to repeat) |
| Schedule         | `r`                    | restart                         |
| Schedule         | `h`                    | toggle info panel               |
| Schedule         | right-drag             | pan                             |
| Schedule         | mouse wheel            | zoom                            |
