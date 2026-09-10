// Five-cycle 0-1-3-4-2-0 with a pendant qubit 5 on 1:
//
//   0 — 1 — 5
//   |   |
//   2   3
//    \ /
//     4
//
// Historically forced CyclicAodOrder and a split-into-rounds fallback in
// the driver; coloring against the fixed AOD sequence (arXiv:2405.08068)
// rejects conflicting colors during coloring, so it routes in a single
// pickup. Kept as the regression case for that coloring. A single round
// still leaves one SLM-SLM edge uncovered (the odd cycle is
// non-bipartite); the driver reroutes the residue in a further round, so
// every CZ lands in the schedule.
OPENQASM 3.0;
qubit[6] q;
bit[6] c;
cz q[0], q[1];
cz q[0], q[2];
cz q[1], q[3];
cz q[1], q[5];
cz q[2], q[4];
cz q[3], q[4];
c = measure q;
