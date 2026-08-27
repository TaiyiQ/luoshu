OPENQASM 3.0;
include "stdgates.inc";

qubit[2] q;
bit[2] c;

// H on q[0]:  H = Rx(pi) Ry(pi/2)  (up to global phase)
ry(pi/2) q[0];
rx(pi)   q[0];

// Native entangler (Rydberg blockade)
cz q[0], q[1];

// Mid-circuit re-preparation of q[0] to |0>
reset q[0];

// H on the freshly reset q[0]
ry(pi/2) q[0];
rx(pi)   q[0];

c = measure q;
