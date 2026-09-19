OPENQASM 3;
include "stdgates.inc";

// Thirteen atoms return to a four-row, six-column storage zone.  The three
// compute-facing rows each have six free sites, while the top row has three.
// The plan therefore contains three physical batches: 6, 6, and 1 atoms.
// The last batch goes to the top row, skipping the still-empty row below it.
qubit[16] q;
bit[16] c;

reset q[0];
reset q[1];
reset q[2];
reset q[3];
reset q[4];
reset q[5];
reset q[6];
reset q[7];
reset q[8];
reset q[9];
reset q[10];
reset q[11];
reset q[12];

c = measure q;
