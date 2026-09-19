OPENQASM 3;
include "stdgates.inc";

// On the paired 4x6 architecture, procedural placement puts four atoms in
// columns 1..4 of every row.  The selected reset atoms create free counts
// [2, 5, 3, 6] from top to bottom.  Eight atoms must therefore use the
// six-site bottom row first.  Of the remaining rows, the two-site top row is
// the exact (and tightest) fit for the last two atoms.
qubit[16] q;
bit[16] c;

reset q[0];
reset q[1];
reset q[2];
reset q[3];
reset q[4];
reset q[8];
reset q[9];
reset q[10];

c = measure q;
