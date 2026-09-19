OPENQASM 3;
include "stdgates.inc";

// Procedural placement on the paired 3x6 architecture is:
//   top:    q8  q9  q10 q11  (columns 1..4)
//   middle: q4  q5  q6  q7   (columns 1..4)
//   bottom: q0  q1  q2  q3   (columns 1..4)
//
// Removing q0, q1, q4, q5, q8 leaves [3, 4, 4] free sites from top to
// bottom.  Five atoms therefore return as batches of four and one.  On the
// bottom row, q2 and q3 block columns 3 and 4.  The first three held atoms
// match columns 0, 1, and 2; the fourth is skipped; and the final atom must
// take column 5 through the NAMapper-style fallback.
qubit[12] q;
bit[12] c;

reset q[0];
reset q[1];
reset q[4];
reset q[5];
reset q[8];

c = measure q;
