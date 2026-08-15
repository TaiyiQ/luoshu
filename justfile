build:
	zig build
	cp ./zig-out/bin/gatecomp .

bench:
	zig build run

ab ref='HEAD~1':
	./bench-ab.sh {{ref}}

test:
	zig build test --summary all

update:
	zig build update-snapshots

fmt:
	zig fmt build.zig build.zig.zon src

check:
	zig fmt --check build.zig build.zig.zon src
