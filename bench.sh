#!/bin/bash
# A/B bench: current tree vs a baseline git ref (default HEAD~1).
#
#   ./bench-ab.sh [suite] [ref]   # suite: all | qasm | mqt | graph
#   ./bench-ab.sh mqt             # one suite vs HEAD~1
#   ./bench-ab.sh 10bc8e2         # ref alone: all suites vs that ref
#   RUNS=5 ./bench-ab.sh          # repetitions per circuit (default 20)
#
# ReleaseFast binaries; the baseline builds once in a throwaway git
# worktree and is cached per commit in zig-out/ab/. Time = min
# compile_ns over RUNS. Mem = peak memory footprint (/usr/bin/time -l),
# one run. Positive % = new binary is better. Flags any circuit whose
# bench JSON (minus compile_ns) differs between the two binaries.
set -euo pipefail
cd "$(dirname "$0")"

RUNS=${RUNS:-20}
CIRCUITS=(ex/qasmbench/*.qasm ex/mqt/*.qasm ex/graph/graph-90-9.qasm)
case "${1:-}" in
    qasm)  CIRCUITS=(ex/qasmbench/*.qasm); shift ;;
    mqt)   CIRCUITS=(ex/mqt/*.qasm); shift ;;
    graph) CIRCUITS=(ex/graph/*.qasm); shift ;;
    all)   shift ;;
esac
SHA=$(git rev-parse --short "${1:-HEAD~1}")
AB=zig-out/ab
mkdir -p "$AB"

echo ">> building current tree"
zig build -Doptimize=ReleaseFast
cp zig-out/bin/gatecomp "$AB/gatecomp-new"

if [[ ! -x $AB/gatecomp-$SHA ]]; then
    echo ">> building baseline $SHA"
    WT=$(mktemp -d)/wt
    git worktree add --quiet "$WT" "$SHA"
    (cd "$WT" && zig build -Doptimize=ReleaseFast)
    cp "$WT/zig-out/bin/gatecomp" "$AB/gatecomp-$SHA"
    git worktree remove --force "$WT"
fi

min_ns() { # <binary> <circuit> <json-out>
    for ((i = 0; i < RUNS; i++)); do
        "$1" "$2" --bench "$3" 2>/dev/null
        jq .compile_ns "$3"
    done | sort -n | head -1
}

peak_mem() { # <binary> <circuit> -> bytes
    /usr/bin/time -l "$1" "$2" 2>&1 >/dev/null |
        awk '/peak memory footprint/ {print $1}'
}

echo ">> $RUNS runs per circuit; base = $SHA"
printf '%-20s %9s %9s %8s %9s %9s %8s\n' \
    circuit 'base(ms)' 'new(ms)' time 'base(MB)' 'new(MB)' mem

for c in "${CIRCUITS[@]}"; do
    base=$AB/gatecomp-$SHA new=$AB/gatecomp-new
    same=''
    bns=$(min_ns "$base" "$c" "$AB/base.json")
    nns=$(min_ns "$new" "$c" "$AB/new.json")
    diff <(jq -S 'del(.compile_ns)' "$AB/base.json") \
         <(jq -S 'del(.compile_ns)' "$AB/new.json") \
        >/dev/null || same='  OUTPUT DIFFERS'
    awk -v c="$(basename "$c" .qasm)" -v s="$same" -v bn="$bns" -v nn="$nns" \
        -v bm="$(peak_mem "$base" "$c")" -v nm="$(peak_mem "$new" "$c")" \
        'BEGIN {
            printf "%-20s %9.3f %9.3f %+7.1f%% %9.2f %9.2f %+7.1f%%%s\n",
                c, bn / 1e6, nn / 1e6, (bn / nn - 1) * 100,
                bm / 1048576, nm / 1048576, (bm / nm - 1) * 100, s
        }'
done
