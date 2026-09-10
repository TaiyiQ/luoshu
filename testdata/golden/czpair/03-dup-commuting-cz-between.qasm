// The gate between the repeats is another CZ: it commutes, so it
// separates nothing. All three would share one stage without the
// pair-split; the repeat must take a second stage.
OPENQASM 3.0;
qubit[3] q;
bit[3] c;
cz q[0], q[1];
cz q[1], q[2];
cz q[0], q[1];
c = measure q;
