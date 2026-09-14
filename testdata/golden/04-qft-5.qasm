// QFT-shaped interaction pattern on 5 qubits: H per qubit, then a CZ
// between every pair (the controlled-phase skeleton) — complete-graph
// routing.
OPENQASM 3.0;
qubit[5] q;
bit[5] c;
h q[0];
cz q[0], q[1];
cz q[0], q[2];
cz q[0], q[3];
cz q[0], q[4];
h q[1];
cz q[1], q[2];
cz q[1], q[3];
cz q[1], q[4];
h q[2];
cz q[2], q[3];
cz q[2], q[4];
h q[3];
cz q[3], q[4];
h q[4];
c = measure q;
