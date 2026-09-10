// MISTAKE: two-qubit gate on one qubit. Parser must reject with a
// located diagnostic ("two-qubit gate on a single qubit").
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cz q[0], q[0];
c = measure q;
