// MISTAKE: cz on an undeclared register. Parser must reject
// (UnknownRegister).
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cz r[0], r[1];
c = measure q;
