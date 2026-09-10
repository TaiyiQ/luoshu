// Odd repeat count: three stages, three pulses, net effect one CZ.
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cz q[0], q[1];
cz q[0], q[1];
cz q[0], q[1];
c = measure q;
