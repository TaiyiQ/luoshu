run circuit="./example/ex1/mvp.qasm":
	zig build run -- {{circuit}} -v --no-draw

# Compile the [benchmark] circuits from config/settings.toml.
bench:
	zig build run

test:
	rm -rf .zig-cache
	zig build test --summary all

update:
	zig build update-snapshots
