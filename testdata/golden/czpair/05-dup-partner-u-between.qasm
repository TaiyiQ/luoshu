// h on a PARTNER qubit is a real separator: the cursor mechanism alone
// splits the stages; the pair-split logic is not involved.
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cz q[0], q[1];
h q[1];
cz q[0], q[1];
c = measure q;
