// Reversed operands are the same pair - must split like 01.
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cz q[0], q[1];
cz q[1], q[0];
c = measure q;
