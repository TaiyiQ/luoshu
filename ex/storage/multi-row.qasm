OPENQASM 3;
include "stdgates.inc";

qubit[7] q;
bit[7] c;

cz q[0], q[1];
cz q[0], q[2];
cz q[0], q[3];
cz q[0], q[4];
cz q[0], q[5];
cz q[0], q[6];

c = measure q;
