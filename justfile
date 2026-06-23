# just run [circuit.qasm] — compile, visualize, and trace the example circuit
run circuit="../qasm/mvp.qasm":
	zig build run -- {{circuit}} --draw -v

test:
	rm -rf .zig-cache
	zig build test --summary all

update:
	zig build update-snapshots

# just bench — compile every bench/circuits/*.qasm on the Fig-13 arch and
# tabulate our metrics against NALAC's Table I (writes bench/results.md)
bench:
	zig build
	python3 bench/compare.py

# just bench-gen [python] — regenerate bench/circuits from MQT Bench 2.2.2.
# Needs an interpreter with `mqt.bench` installed, e.g.
#   just bench-gen .venv/bin/python
bench-gen python="python3":
	{{python}} bench/generate.py
