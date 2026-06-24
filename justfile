run circuit="../qasm/mvp.qasm":
	zig build run -- {{circuit}} --draw -v

test:
	rm -rf .zig-cache
	zig build test --summary all

update:
	zig build update-snapshots
