OPENQASM 3;
include "stdgates.inc";

qubit[5] q;
bit[5] c;

cz q[0], q[1];
cz q[0], q[2];
cz q[0], q[3];
cz q[0], q[4];

c = measure q;
