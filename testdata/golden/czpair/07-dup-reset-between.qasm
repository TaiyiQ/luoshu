// reset on a partner does not commute with CZ: the repeat is legitimate
// non-canceling structure, split by cursors around the reset stage.
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cz q[0], q[1];
reset q[0];
cz q[0], q[1];
c = measure q;
