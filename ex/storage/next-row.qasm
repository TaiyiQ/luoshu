OPENQASM 3;
include "stdgates.inc";

qubit[6] q;
bit[6] c;

cz q[0], q[1];
cz q[1], q[2];
cz q[2], q[3];
cz q[3], q[4];
cz q[4], q[5];
cz q[5], q[0];

c = measure q;
