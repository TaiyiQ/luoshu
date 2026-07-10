run:
	zig build run -- ./ex/graph/graph-90-9.qasm --viz gui

bench:
	zig build run

test:
	rm -rf .zig-cache
	zig build test --summary all

update:
	zig build update-snapshots
