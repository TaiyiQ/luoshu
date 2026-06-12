// Triggers error.CyclicAodOrder in the router: bare CZs with no U
// barriers all land in one stage, so this entire interaction graph is
// routed at once.
//
//   0 — 1 — 5      the five-cycle 0-1-3-4-2-0
//   |   |          with a pendant qubit 5 on 1
//   2   3
//    \ /
//     4
//
// The deterministic edge coloring picks AODs {1, 4} and colors
//   1: 0@c0, 3@c1, 5@c2      4: 2@c0, 3@c2
// giving the SLM slot order 0 < 2 < 3 < 5. Color class 0 then has the
// pairs (1,0) and (4,2), forcing column 1 left of column 4; color class
// 2 has (1,5) and (4,3), forcing column 4 left of column 1. No rigid
// AOD column order satisfies both, so the router rejects the coloring
// instead of emitting a schedule with crossing columns.
OPENQASM 3;
include "stdgates.inc";

qubit[6] q;

cz q[0], q[1];
cz q[0], q[2];
cz q[1], q[3];
cz q[1], q[5];
cz q[2], q[4];
cz q[3], q[4];
