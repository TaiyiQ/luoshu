#!/usr/bin/env bash
#
# A/B bench: current tree vs a baseline git ref.
#
#   ./bench.sh <suite> <commit>      # suite: qasm | mqt | graph
#   ./bench.sh mqt ab12
#   RUNS=5 ./bench.sh qasm 10bc8e2
#
# ReleaseFast binaries; the baseline builds once in a throwaway git
# worktree and is cached per commit in zig-out/ab/. Time = min
# compile_ns over RUNS. Mem = peak memory footprint (/usr/bin/time -l),
# one run. Positive % = new binary is better. Flags any circuit whose
# bench JSON (minus compile_ns) differs between the two binaries.

set -euo pipefail

cd "$(dirname "$0")"

[[ -z ${1:-} ]] && echo "usage: $0 <suite> <ref>   suite: qasm | mqt | graph" && exit 1
[[ -z ${2:-} ]] && echo "usage: $0 <suite> <ref>   ref: baseline git commit" && exit 1

case "$1" in
    qasm)  CIRCUITS=(ex/qasmbench/*.qasm) ;;
    mqt)   CIRCUITS=(ex/mqt/*.qasm) ;;
    graph) CIRCUITS=(ex/graph/*.qasm) ;;
    *)     echo "unknown suite: $1 (want all | qasm | mqt | graph)" && exit 1 ;;
esac

RUNS=${RUNS:-20}
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

min_ns() { # <binary> <circuit> <json-out>
    local i

    for ((i = 0; i < RUNS; i++)); do
        "$1" "$2" --bench "$3" 2>/dev/null
        jq .compile_ns "$3"
    done | sort -n | head -1
}

peak_mem() { # <binary> <circuit> -> bytes
    /usr/bin/time -l "$1" "$2" 2>&1 >/dev/null |
        awk '/peak memory footprint/ {print $1}'
}

run_bench() {
    local base="$AB/gatecomp-$SHA" new="$AB/gatecomp-new"
    local c same bns nns

    echo ">> $RUNS runs per circuit; base = $SHA"
    printf '%-20s %9s %9s %8s %9s %9s %8s\n' \
        circuit 'base(ms)' 'new(ms)' time 'base(MB)' 'new(MB)' mem

    for c in "${CIRCUITS[@]}"; do
        same=''

        bns=$(min_ns "$base" "$c" "$AB/base.json")
        nns=$(min_ns "$new" "$c" "$AB/new.json")

        diff <(jq -S 'del(.compile_ns)' "$AB/base.json") \
             <(jq -S 'del(.compile_ns)' "$AB/new.json") \
            >/dev/null || same='  OUTPUT DIFFERS'

        awk -v c="$(basename "$c" .qasm)" \
			-v s="$same" \
			-v bn="$bns" \
			-v nn="$nns" \
            -v bm="$(peak_mem "$base" "$c")" \
			-v nm="$(peak_mem "$new" "$c")" \
            'BEGIN {
                printf "%-20s %9.3f %9.3f %+7.1f%% %9.2f %9.2f %+7.1f%%%s\n",
                    c, bn / 1e6, nn / 1e6, (bn / nn - 1) * 100,
                    bm / 1048576, nm / 1048576, (bm / nm - 1) * 100, s
            }'
    done
}

build_binaries
run_bench

exit 0
