#!/usr/bin/env bash
#
# A/B hardware-cost bench: current tree vs a baseline git ref.
#
#   ./script/bench-hardware.sh <suite> <commit>      # suite: qasm | mqt | graph
#   ./script/bench-hardware.sh mqt ab12
#
# Compares the modeled neutral-atom hardware cost of the emitted
# schedules: shut = time_us.shuttling (per-frame max move / speed) and
# route = time_us.routing (loading + shuttling), so route - shut is the
# load/store cost. Gate pulses are negligible next to shuttling, which
# is why there is no total column — it would just repeat route.
# These are deterministic properties of the schedule, so each circuit
# runs once per binary — no timing loop, full suites sweep fast.
# ReleaseFast binaries; the baseline builds once in a throwaway git
# worktree and is cached per commit in zig-out/ab/. Positive % = new
# binary is better. Flags any circuit whose bench JSON (minus
# compile_ns) differs between the two binaries.

set -euo pipefail

cd "$(dirname "$0")/.."

[[ -z ${1:-} ]] && echo "usage: $0 <suite> <ref>   suite: qasm | mqt | graph" && exit 1
[[ -z ${2:-} ]] && echo "usage: $0 <suite> <ref>   ref: baseline git commit" && exit 1

case "$1" in
    qasm)  CIRCUITS=(ex/qasmbench/*.qasm) ;;
    mqt)   CIRCUITS=(ex/mqt/*.qasm) ;;
    graph) CIRCUITS=(ex/graph/*.qasm) ;;
    *)     echo "unknown suite: $1 (want qasm | mqt | graph)" && exit 1 ;;
esac

SHA=$(git rev-parse --short "$2")
AB=zig-out/ab

build_binaries() {
    local wt

    echo ">> building current tree"
    zig build -Doptimize=ReleaseFast
    mkdir -p "$AB"
    cp zig-out/bin/gatecomp "$AB/gatecomp-new"

    if [[ ! -x $AB/gatecomp-$SHA ]]; then
        echo ">> building baseline $SHA"
        wt=$(mktemp -d)/wt
        git worktree add --quiet "$wt" "$SHA"
        (cd "$wt" && zig build -Doptimize=ReleaseFast)
        cp "$wt/zig-out/bin/gatecomp" "$AB/gatecomp-$SHA"
        git worktree remove --force "$wt"
    fi
}

bench_json() { # <binary> <circuit> <json-out>
    local old stem
    stem=$(basename "$2" .qasm)
    # Pre-merge binaries take --bench <file>; current ones --out <dir>.
    old=$("$1" -h 2>&1 | grep -c -- '--bench ' || true)

    if [[ $old -gt 0 ]]; then
        "$1" "$2" --bench "$3" 2>/dev/null
    else
        "$1" "$2" --out "$AB" 2>/dev/null
        mv "$AB/$stem-bench.json" "$3"
    fi
}

run_bench() {
    local base="$AB/gatecomp-$SHA" new="$AB/gatecomp-new"
    local c same bsh nsh brt nrt

    echo ">> base = $SHA"
    printf '%-20s %10s %10s %8s %10s %10s %8s\n' \
        circuit 'base(us)' 'new(us)' shut 'base(us)' 'new(us)' route

    for c in "${CIRCUITS[@]}"; do
        same=''

        bench_json "$base" "$c" "$AB/base.json"
        bench_json "$new" "$c" "$AB/new.json"

        bsh=$(jq '.time_us.shuttling // 0' "$AB/base.json")
        nsh=$(jq '.time_us.shuttling // 0' "$AB/new.json")
        brt=$(jq '.time_us.routing // 0' "$AB/base.json")
        nrt=$(jq '.time_us.routing // 0' "$AB/new.json")

        diff <(jq -S 'del(.compile_ns)' "$AB/base.json") \
             <(jq -S 'del(.compile_ns)' "$AB/new.json") \
            >/dev/null || same='  OUTPUT DIFFERS'

        awk -v c="$(basename "$c" .qasm)" \
			-v s="$same" \
			-v bsh="$bsh" \
			-v nsh="$nsh" \
			-v brt="$brt" \
			-v nrt="$nrt" \
            'function pct(b, n) { return n > 0 ? (b / n - 1) * 100 : 0 }
            BEGIN {
                printf "%-20s %10.1f %10.1f %+7.1f%% %10.1f %10.1f %+7.1f%%%s\n",
                    c, bsh, nsh, pct(bsh, nsh),
                    brt, nrt, pct(brt, nrt), s
            }'
    done
}

build_binaries
run_bench

exit 0
