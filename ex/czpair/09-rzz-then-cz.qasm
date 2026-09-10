// rzz ends its decomposition with h on the target, so a trailing cz on
// the same pair is separated by cursors, not by the pair-split.
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
rzz(0.5) q[0], q[1];
cz q[0], q[1];
c = measure q;
