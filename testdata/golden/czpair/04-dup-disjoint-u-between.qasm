// h on an UNRELATED qubit does not advance the pair's cursors, so this
// still needs the pair-split (the sneaky case: looks separated, is not).
OPENQASM 3.0;
qubit[3] q;
bit[3] c;
cz q[0], q[1];
h q[2];
cz q[0], q[1];
c = measure q;
