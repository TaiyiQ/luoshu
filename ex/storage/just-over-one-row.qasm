OPENQASM 3;
include "stdgates.inc";

// The star produces a one-atom AOD return followed by a nine-atom fixed
// return.  A storage row has only eight sites, so the latter return must be
// split even though it exceeds one row by only one atom.
qubit[10] q;
bit[10] c;

cz q[0], q[1];
cz q[0], q[2];
cz q[0], q[3];
cz q[0], q[4];
cz q[0], q[5];
cz q[0], q[6];
cz q[0], q[7];
cz q[0], q[8];
cz q[0], q[9];

c = measure q;
