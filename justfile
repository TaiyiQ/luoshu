build:
	zig build
	cp ./zig-out/bin/gatecomp .

bench:
	zig build run

test:
	rm -rf .zig-cache
	zig build test --summary all

update:
	zig build update-snapshots
