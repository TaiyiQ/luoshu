OPENQASM 3.0;
include "stdgates.inc";

// Whole-register reset: `reset q;` expands to one front-end op per qubit,
// and all four land in a single reset stage — one shared round trip to the
// readout zone, and the schedule carries exactly ONE reset op:
// { "op": "reset", "zone": "readout", "qubits": [0, 1, 2, 3] }.

qubit[4] q;
bit[4] c;

// GHZ-4
h q[0];
cx q[0], q[1];
cx q[1], q[2];
cx q[2], q[3];

// Discard the entangled state and start over.
reset q;

// Fresh superposition on every wire.
h q[0];
h q[1];
h q[2];
h q[3];

c = measure q;
