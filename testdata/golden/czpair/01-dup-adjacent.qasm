// cz;cz on one pair: CZ^2 = I. Must compile as TWO pulses (decompose
// splits the repeat into its own stage), never merge into one.
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cz q[0], q[1];
cz q[0], q[1];
c = measure q;
