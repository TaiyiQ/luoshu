OPENQASM 3;
include "stdgates.inc";

// My modified version to check pickup algorithm.

qubit[9] q;

cz q[1], q[3];
cz q[2], q[5];
cz q[0], q[1];
cz q[0], q[4];
cz q[0], q[8];
cz q[0], q[3];
