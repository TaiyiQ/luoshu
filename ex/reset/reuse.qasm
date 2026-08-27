OPENQASM 3.0;
include "stdgates.inc";

// Qubit reuse on a single wire: h; reset; h; reset; h. Each H flips q0's
// virtual-Z frame to pi, and each reset must void it — so all three H
// pulses serialize with the SAME drive phase. If the frame-phase zeroing
// in compiler.zig regresses, the second and third phases drift.

qubit[1] q;
bit[1] c;

h q[0];
reset q[0];
h q[0];
reset q[0];
h q[0];

c[0] = measure q[0];
