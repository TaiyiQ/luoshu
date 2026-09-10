// CZ on every edge of a 3x3 grid — one big stage, maximum routing
// pressure.
//
//   0-1-2
//   | | |
//   3-4-5
//   | | |
//   6-7-8
OPENQASM 3.0;
qubit[9] q;
bit[9] c;
cz q[0], q[1];
cz q[1], q[2];
cz q[3], q[4];
cz q[4], q[5];
cz q[6], q[7];
cz q[7], q[8];
cz q[0], q[3];
cz q[3], q[6];
cz q[1], q[4];
cz q[4], q[7];
cz q[2], q[5];
cz q[5], q[8];
c = measure q;
