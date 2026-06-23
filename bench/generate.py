#!/usr/bin/env python3
"""Generate the NALAC (arXiv:2405.08068) Table I benchmark circuits.

Pulls each family from MQT Bench 2.2.2 at 20 qubits, transpiles to the gate set
our compiler accepts ({rx, ry, rz, cz} — the paper's "local + global rotations
and CZ"), and writes OpenQASM 3 into bench/circuits/.

Requires a venv with `mqt.bench==2.2.2` (pulls qiskit). The paper used MQT Bench
1.x, so a few families differ:
  - portfoliovqe was removed in 2.x (skipped).
  - realamprandom/su2random/twolocalrandom are renamed vqe_real_amp/vqe_su2/
    vqe_two_local, and the 2.x ansatz repetition counts differ from 1.x, so
    their CZ counts drift from the paper (see bench/README.md).

Usage:  <venv>/bin/python bench/generate.py
"""
from mqt.bench import get_benchmark, BenchmarkLevel
from qiskit import transpile
from qiskit.qasm3 import dumps
import os

# paper family -> mqt.bench 2.2.2 identifier
FAMILIES = {
    "ae": "ae", "dj": "dj", "ghz": "ghz", "graphstate": "graphstate",
    "qft": "qft", "qftentangled": "qftentangled", "qnn": "qnn",
    "qpeexact": "qpeexact", "qpeinexact": "qpeinexact",
    "realamprandom": "vqe_real_amp", "su2random": "vqe_su2",
    "twolocalrandom": "vqe_two_local", "wstate": "wstate",
    # "portfoliovqe": removed in mqt.bench 2.x
}
BASIS = ["rx", "ry", "rz", "cz"]
OUTDIR = os.path.join(os.path.dirname(__file__), "circuits")


def main() -> None:
    os.makedirs(OUTDIR, exist_ok=True)
    print(f"{'paper_name':16} {'qubits':>6} {'cz':>6}  file")
    for paper, ident in FAMILIES.items():
        qc = get_benchmark(ident, BenchmarkLevel.ALG, 20)
        tqc = transpile(qc, basis_gates=BASIS, optimization_level=1, seed_transpiler=0)
        cz = tqc.count_ops().get("cz", 0)
        path = os.path.join(OUTDIR, f"{paper}_20.qasm")
        with open(path, "w") as f:
            f.write(dumps(tqc))
        print(f"{paper:16} {tqc.num_qubits:>6} {cz:>6}  {path}")


if __name__ == "__main__":
    main()
