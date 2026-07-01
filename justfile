run circuit="./example/ex1/mvp.qasm":
	zig build run -- {{circuit}} -v --no-draw

test:
	rm -rf .zig-cache
	zig build test --summary all

update:
	zig build update-snapshots
