// Repeated edge on a triangle: stage 0 is the full triangle (forces the
// multi-round residue loop in routing), stage 1 is the repeat. Coverage
// must see (0,1) twice plus the other two edges once each.
OPENQASM 3.0;
qubit[3] q;
bit[3] c;
cz q[0], q[1];
cz q[1], q[2];
cz q[2], q[0];
cz q[0], q[1];
c = measure q;
