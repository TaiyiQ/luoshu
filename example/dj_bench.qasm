// Benchmark created by MQT Bench on 2026-05-28
// For more info: https://mqt-bench.app/
// MQT Bench version: 2.2.2
// Qiskit version: 2.4.1
// Output format: qasm3
// Level: nativegates
// Target: neutral_atom
// Used gateset: ['rz', 'rx', 'ry', 'cz', 'reset', 'delay', 'measure']

OPENQASM 3.0;
include "stdgates.inc";

bit[4] c;
qubit[5] q;

ry(pi/2) q[0];
ry(pi/2) q[1];
ry(-pi/2) q[2];
rz(-pi) q[2];
ry(-pi/2) q[3];
rz(-pi) q[3];
rx(pi) q[4];
cz q[0], q[4];
ry(-pi/2) q[0];
cz q[1], q[4];
ry(-pi/2) q[1];
cz q[2], q[4];
ry(-pi/2) q[2];
rz(-pi) q[2];
cz q[3], q[4];
ry(-pi/2) q[3];
rz(-pi) q[3];
ry(-pi/2) q[4];
rz(-pi) q[4];

barrier q[0], q[1], q[2], q[3], q[4];

c[0] = measure q[0];
c[1] = measure q[1];
c[2] = measure q[2];
c[3] = measure q[3];
