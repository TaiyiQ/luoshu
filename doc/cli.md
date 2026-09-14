# CLI

```shell
luoshu <circuit.qasm>... [options]
```

Compiles each circuit given. Several circuits run as a benchmark suite: a metrics table prints per circuit and the visualizer stays closed. Inputs come from flags **or** from a config file, never both.

## Mode 1: Flags - name the inputs on the command line:

```shell
luoshu circuit.qasm --arch cfg/arch.toml --asm cfg/assembly.json --out zig-out
```

- `--arch <file>` — architecture TOML (default: `cfg/arch.toml`)
- `--asm <file>` — storage occupancy JSON from the upstream atom-rearrangement package; omitting it uses procedural placement
- `--out <dir>` — directory for job outputs: each circuit writes `<name>-schedule.json` and `<name>-bench.json` (see [schedule.md](schedule.md) and [benchmark.md](benchmark.md)); omitting it writes nothing

## Mode 2: Config - reference a settings TOML instead:

```shell
luoshu circuit.qasm --cfg cfg/settings.toml
```

The file carries the same three inputs as an `[options]` table; commented-out keys fall back to the built-in defaults:

```toml
[options]
arch = "cfg/arch.toml"
assembly = "cfg/assembly.json"
out = "zig-out/bench"
```

Mixing `--cfg` with `--arch`, `--asm`, or `--out` is an error — set the value in the config file instead. With neither flags nor `--cfg`, the built-in defaults apply.

## Toggles

Runtime toggles are CLI-only and work in either mode:

- `--viz`: open the schedule visualizer (off by default; single-circuit runs only)
- `-v`, `--verbose`: trace the compiler passes to `stderr`
