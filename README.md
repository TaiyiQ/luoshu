# Gate Compiler

Compiles [OpenQASM 3](https://openqasm.com/) circuits into a hardware schedule for a neutral-atom quantum computer — native U/CZ transpilation, qubit routing, and atom-move / pulse scheduling.

## Requirements

- [zig](https://ziglang.org/) ≥ 0.16 (dependencies are fetched by `zig build`)
- [just](https://github.com/casey/just) — optional, mostly for developers.

## Usage

```
gatecomp <circuit.qasm> [options]

options:
  --arch <file>       architecture TOML (default: ./arch.toml)
  --asm <file>        storage-occupancy JSON from the upstream
                      atom-rearrangement package
  --out <path>        write the hardware schedule as JSON
  --draw / --no-draw  open the schedule visualization (default: on)
  -v, --verbose       trace the compiler passes to stderr
  -h, --help          show this help
```

Compile a circuit to a hardware-schedule JSON:

```shell
zig build run -- ../qasm/mvp.qasm --out schedule.json
```

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
