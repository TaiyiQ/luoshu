OPENQASM 3;
include "stdgates.inc";

qubit[8] q;
bit[8] c;

cz q[1], q[2];
cz q[3], q[4];
cz q[6], q[7];
cz q[1], q[6];
cz q[2], q[7];
cz q[4], q[7];
cz q[5], q[7];

u(0,0,0) q[0];
u(0,0,0) q[1];
u(0,0,0) q[2];

cz q[1], q[2];
cz q[3], q[5];
cz q[4], q[5];

c = measure q;
