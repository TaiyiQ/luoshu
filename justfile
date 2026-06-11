# just run [circuit.qasm] — compile, visualize, and trace the example circuit
run circuit="../qasm/mvp.qasm":
	zig build run -- {{circuit}} --draw -v

test:
	zig build test

update-snapshots:
	zig build update-snapshots
