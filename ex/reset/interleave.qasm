OPENQASM 3.0;
include "stdgates.inc";

// Partial reset between two entangling layers. The three disjoint resets
// merge into one reset stage (one round trip, qubits [0, 2, 4]) sandwiched
// between two routed CZ episodes. The reset barriers only its own qubits:
// q[1], q[3], q[5] keep their accumulated rz frame phase across it, so
// their final H pulses serialize with a different drive phase than the
// reset qubits'.

qubit[6] q;
bit[6] c;

h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];

// First entangling layer: a CZ chain.
cz q[0], q[1];
cz q[2], q[3];
cz q[4], q[5];

// Accumulate a virtual-Z on every wire...
rz(pi / 3) q[0];
rz(pi / 3) q[1];
rz(pi / 3) q[2];
rz(pi / 3) q[3];
rz(pi / 3) q[4];
rz(pi / 3) q[5];

// ...then wipe the even wires only.
reset q[0];
reset q[2];
reset q[4];

// Second entangling layer, shifted by one.
cz q[1], q[2];
cz q[3], q[4];

h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];

c = measure q;
