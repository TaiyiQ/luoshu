OPENQASM 3;
include "stdgates.inc";

qubit[5] q;

cz q[1], q[2];
cz q[1], q[3];

u(0,0,0) q[0];
u(0,0,0) q[1];

cz q[1], q[2];
cz q[0], q[1];
cz q[2], q[3];

u(0,0,0) q[1];
u(0,0,0) q[2];

cz q[3], q[4];
