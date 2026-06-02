OPENQASM 3.0;
include "stdgates.inc";

qubit[2] q;
bit[2] c;

// H on q[0]:  H = Rx(pi) Ry(pi/2)  (up to global phase)
ry(pi/2) q[0];
rx(pi)   q[0];

// H on q[1]
ry(pi/2) q[1];
rx(pi)   q[1];

// Native entangler (Rydberg blockade)
cz q[0], q[1];

// Second H on q[1] completes CNOT(0,1)
ry(pi/2) q[1];
rx(pi)   q[1];
