OPENQASM 3;
include "stdgates.inc";

// Phase 1 deterministically exercises the sparse-row fallback used by
// fallback-right-edge.qasm.  The H wave forms a dependency barrier.  Phase 2
// then routes a 12-cycle from the new storage layout, causing several AOD and
// fixed registers to return through compressToStorage again.
qubit[12] q;
bit[12] c;

reset q[0];
reset q[1];
reset q[4];
reset q[5];
reset q[8];

h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
h q[8];
h q[9];
h q[10];
h q[11];

cz q[0], q[1];
cz q[1], q[2];
cz q[2], q[3];
cz q[3], q[4];
cz q[4], q[5];
cz q[5], q[6];
cz q[6], q[7];
cz q[7], q[8];
cz q[8], q[9];
cz q[9], q[10];
cz q[10], q[11];
cz q[11], q[0];

c = measure q;
