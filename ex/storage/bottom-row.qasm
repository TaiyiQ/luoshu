OPENQASM 3;
include "stdgates.inc";

qubit[2] q;
bit[2] c;

cz q[0], q[1];

c = measure q;
