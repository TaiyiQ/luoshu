#!/usr/bin/env python3
"""Compile each benchmark circuit and tabulate our metrics against NALAC's
Table I (arXiv:2405.08068).

Runs `gatecomp --bench` on every circuit in bench/circuits/ with the Figure-13
architecture, reads the emitted metrics JSON, and prints a Markdown table next
to the paper's reported numbers. Stdlib only — uses the built binary, not the
venv.

Build the binary first:  zig build
Usage:                    python3 bench/compare.py
"""
import json
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "zig-out", "bin", "gatecomp")
ARCH = os.path.join(ROOT, "bench", "arch-fig13.toml")
CIRCUITS = os.path.join(ROOT, "bench", "circuits")

# NALAC Table I (20 logical qubits): cz_gates, naive_ms, nalac_ms, parallel(NALAC)
PAPER = {
    "ae": (380, 130, 32, 1.1), "dj": (19, 7, 1, 1.0), "ghz": (19, 6, 7, 1.0),
    "graphstate": (20, 7, 1, 3.3), "qft": (408, 139, 22, 1.0),
    "qftentangled": (429, 147, 31, 2.8), "qnn": (778, 266, 57, 3.6),
    "qpeexact": (406, 139, 43, 3.7), "qpeinexact": (407, 139, 43, 3.7),
    "realamprandom": (570, 195, 27, 1.2), "su2random": (570, 195, 27, 1.2),
    "twolocalrandom": (570, 195, 27, 1.2), "wstate": (38, 13, 7, 1.0),
}


def run(name: str):
    qasm = os.path.join(CIRCUITS, f"{name}_20.qasm")
    if not os.path.exists(qasm):
        return None, "no circuit"
    fd, out = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.remove(out)  # let the compiler create it; absence means it failed
    try:
        r = subprocess.run(
            [BIN, qasm, "--arch", ARCH, "--asm", "none", "--no-draw", "--bench", out],
            capture_output=True, text=True, timeout=900,
        )
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if not os.path.exists(out):
        # prefer the Zig error name; fall back to the last meaningful line
        err_lines = [ln.strip() for ln in r.stderr.splitlines()
                     if "error" in ln.lower() and ".zig:" not in ln and "^" not in ln]
        if err_lines:
            return None, err_lines[0][:48]
        lines = [ln.strip() for ln in r.stderr.splitlines() if ln.strip() and "^" not in ln]
        return None, (lines[-1][:48] if lines else "compile failed")
    m = json.load(open(out))
    os.remove(out)
    return m, None


HEADERS = ["circuit", "CZ paper", "CZ ours", "∥ paper", "∥ ours", "route ms NALAC", "route ms ours"]
# left-align the name, right-align every numeric column
ALIGNS = ["<", ">", ">", ">", ">", ">", ">"]


def render(data: list[list[str]]) -> str:
    """Pad cells to a fixed width per column so the table aligns in a monospace
    terminal while staying valid GitHub-flavoured Markdown."""
    widths = [max([len(HEADERS[c])] + [len(row[c]) for row in data]) for c in range(len(HEADERS))]

    def row(cells: list[str]) -> str:
        cooked = [c.ljust(w) if a == "<" else c.rjust(w) for c, w, a in zip(cells, widths, ALIGNS)]
        return "| " + " | ".join(cooked) + " |"

    def sep() -> str:
        cells = []
        for w, a in zip(widths, ALIGNS):
            cells.append(":" + "-" * (w - 1) if a == "<" else "-" * (w - 1) + ":")
        return "| " + " | ".join(cells) + " |"

    return "\n".join([row(HEADERS), sep()] + [row(r) for r in data])


def main() -> None:
    data: list[list[str]] = []
    for name, (czp, _naive, nalac, par) in PAPER.items():
        m, err = run(name)
        if m is None:
            data.append([name, str(czp), "—", str(par), "—", str(nalac), f"_{err}_"])
            continue
        czo = m["entangling"]["cz_pairs"]
        po = m["entangling"]["avg_cz_per_pulse"]
        ro = m["time_us"]["routing"] / 1000.0
        data.append([name, str(czp), str(czo), str(par), f"{po:.2f}", str(nalac), f"{ro:.1f}"])

    table = render(data)
    print(table)
    with open(os.path.join(ROOT, "bench", "results.md"), "w") as f:
        f.write("# gate-compiler vs NALAC Table I (20 qubits)\n\n" + table + "\n")


if __name__ == "__main__":
    main()
