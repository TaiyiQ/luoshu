build:
	zig build
	cp ./zig-out/bin/gatecomp .

run:
	zig build run

bench *args:
	./bench.sh {{args}}

test:
	zig build test --summary all

update:
	zig build update-snapshots

fmt:
	zig fmt build.zig build.zig.zon src

check:
	zig fmt --check build.zig build.zig.zon src
