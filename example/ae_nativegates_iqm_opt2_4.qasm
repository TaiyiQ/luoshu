// Benchmark created by MQT Bench on 2026-05-28
// For more info: https://mqt-bench.app/
// MQT Bench version: 2.2.1
// Qiskit version: 2.1.1
// Output format: qasm3
// Level: nativegates
// Target: iqm
// Used gateset: ['r', 'cz', 'reset', 'delay', 'measure', 'if_else']

OPENQASM 3.0;
include "stdgates.inc";
gate r(p0, p1) _gate_q_0 {
  U(p0, -pi/2 + p1, pi/2 - p1) _gate_q_0;
}
bit[4] meas;
r(0.06145834009733498, -pi) $0;
r(pi/4, 0) $1;
r(-pi/2, pi/2) $2;
r(pi, 0.09869777992494067) $2;
r(-pi/2, -pi) $3;
r(pi, pi/4) $3;
cz $3, $0;
r(-2.214297435588181, 0) $0;
r(pi, pi/4) $0;
r(pi, -pi/4) $3;
cz $3, $0;
r(-pi/2, -pi) $0;
r(pi, 2.19057411939165) $0;
r(-pi, 2.8521054384263653) $3;
r(pi, 0.6378080028381836) $3;
cz $3, $1;
r(-1.8545904360032246, 0) $1;
r(pi, pi/4) $1;
r(pi, -pi/4) $3;
cz $3, $1;
r(-pi/2, -pi) $1;
r(pi, 0) $1;
r(-pi/2, 1.8545904360032246) $3;
r(pi, 0.1418970546041649) $3;
cz $2, $3;
r(pi, -pi/4) $2;
r(-2.574004435173137, 0) $3;
r(pi, pi/4) $3;
cz $2, $3;
r(-pi, 0.6875380808449654) $2;
r(pi, 1.5716340241673539) $2;
cz $1, $2;
r(-3*pi/4, 0) $2;
r(pi, -pi) $2;
cz $1, $2;
r(-pi, -pi) $1;
r(pi, 0) $1;
r(-3*pi/4, -pi) $2;
r(pi, 0) $2;
cz $0, $2;
r(-7*pi/8, 0) $2;
r(pi, -pi) $2;
cz $0, $2;
r(-pi, 5*pi/8) $0;
r(pi, pi/2) $0;
cz $0, $1;
r(-3*pi/4, 0) $1;
r(pi, -pi) $1;
cz $0, $1;
r(pi/2, pi/2) $0;
r(pi, 0) $0;
r(-pi/2, -pi/2) $1;
r(pi, -pi/8) $1;
r(-pi/2, -pi/2) $2;
r(pi, -pi/16) $2;
r(-2.1383845452115517, pi/2) $3;
r(pi, 0) $3;
barrier $0, $1, $2, $3;
meas[0] = measure $0;
meas[1] = measure $1;
meas[2] = measure $2;
meas[3] = measure $3;
