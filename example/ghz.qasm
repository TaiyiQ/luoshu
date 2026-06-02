OPENQASM 3;
include "stdgates.inc";

// https://mqt.readthedocs.io/projects/qmap/en/latest/na_zoned_compiler.html

qubit[8] q;

cz q[0], q[4];

u(0,0,0) q[4];

cz q[0], q[2];
cz q[4], q[6];

u(0,0,0) q[2];
u(0,0,0) q[6];

cz q[0], q[1];
cz q[2], q[3];
cz q[4], q[5];
cz q[6], q[7];

u(0,0,0) q[1];
u(0,0,0) q[3];
u(0,0,0) q[5];
u(0,0,0) q[7];
