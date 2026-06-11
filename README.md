# Gate Compiler

## Usage

```
gatecomp <circuit.qasm> [options]

options:
  --arch <file>       architecture TOML (default: example/arch.toml)
  --emit-json <path>  write the hardware schedule as JSON
  --draw              open the schedule visualization
  -v, --verbose       trace the compiler passes to stderr
  -h, --help          show this help
```

- Compile, visualize, and trace the main example circuit:
```shell
> just run
```

- Compile a circuit to a hardware schedule JSON:
```shell
> zig build run -- ../qasm/mvp.qasm --emit-json schedule.json
```
