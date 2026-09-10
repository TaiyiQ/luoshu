OPENQASM 3.0;
include "stdgates.inc";

qubit[4] q;
bit[4] c;

// -- Bell pair 1: q[0], q[1] --
ry(pi/2) q[0];
rx(pi)   q[0];

ry(pi/2) q[1];
rx(pi)   q[1];

cz q[0], q[1];

ry(pi/2) q[1];
rx(pi)   q[1];

// -- Bell pair 2: q[2], q[3] --
ry(pi/2) q[1];
rx(pi)   q[1];

ry(pi/2) q[2];
rx(pi)   q[2];

cz q[1], q[2];

ry(pi/2) q[2];
rx(pi)   q[2];

// -- Bell pair 3: q[4], q[5] --
ry(pi/2) q[2];
rx(pi)   q[2];

ry(pi/2) q[3];
rx(pi)   q[3];

cz q[2], q[3];

ry(pi/2) q[3];
rx(pi)   q[3];

c = measure q;
