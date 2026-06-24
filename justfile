run circuit="../qasm/mvp.qasm":
	zig build run -- {{circuit}} --draw -v

test:
	rm -rf .zig-cache
	zig build test --summary all

update:
	zig build update-snapshots

bench:
	zig build run -- "../bench-compiler/circuits/ghz_20.qasm" --arch "arch.toml" --asm none --no-draw --bench bench.json
