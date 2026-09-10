// CZ ring over 6 qubits — the even cycle from route.zig's coverage
// test, taken through the full pipeline. Its first timeframe places the
// AOD atoms away from the leftmost compute columns, pinning down that
// the entry move stores atoms directly at their first-timeframe
// positions.
OPENQASM 3.0;
qubit[6] q;
bit[6] c;
cz q[0], q[1];
cz q[1], q[2];
cz q[2], q[3];
cz q[3], q[4];
cz q[4], q[5];
cz q[5], q[0];
c = measure q;
