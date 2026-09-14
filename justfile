build:
	zig build
	cp ./zig-out/bin/gatecomp .

run:
	zig build run

bench-wc *args:
	./script/bench-wallclock.sh {{args}}

bench-hw *args:
	./script/bench-hardware.sh {{args}}

test:
	zig build test --summary all

update:
	zig build update-goldens

fmt:
	zig fmt build.zig build.zig.zon src

check:
	zig fmt --check build.zig build.zig.zon src
