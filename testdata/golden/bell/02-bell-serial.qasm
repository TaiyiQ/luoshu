OPENQASM 3.0;
include "stdgates.inc";

qubit[20] q;
bit[20] c;

// -- Bell pair 1: q[0], q[1] --
ry(pi/2) q[0];
rx(pi)   q[0];

ry(pi/2) q[1];
rx(pi)   q[1];

cz q[0], q[1];

ry(pi/2) q[1];
rx(pi)   q[1];

// -- Bell pair 2: q[2], q[3] --
ry(pi/2) q[2];
rx(pi)   q[2];

ry(pi/2) q[3];
rx(pi)   q[3];

cz q[2], q[3];

ry(pi/2) q[3];
rx(pi)   q[3];

// -- Bell pair 3: q[4], q[5] --
ry(pi/2) q[4];
rx(pi)   q[4];

ry(pi/2) q[5];
rx(pi)   q[5];

cz q[4], q[5];

ry(pi/2) q[5];
rx(pi)   q[5];

// -- Bell pair 4: q[6], q[7] --
ry(pi/2) q[6];
rx(pi)   q[6];

ry(pi/2) q[7];
rx(pi)   q[7];

cz q[6], q[7];

ry(pi/2) q[7];
rx(pi)   q[7];

// -- Bell pair 5: q[8], q[9] --
ry(pi/2) q[8];
rx(pi)   q[8];

ry(pi/2) q[9];
rx(pi)   q[9];

cz q[8], q[9];

ry(pi/2) q[9];
rx(pi)   q[9];

// -- Bell pair 6: q[10], q[11] --
ry(pi/2) q[10];
rx(pi)   q[10];

ry(pi/2) q[11];
rx(pi)   q[11];

cz q[10], q[11];

ry(pi/2) q[11];
rx(pi)   q[11];

// -- Bell pair 7: q[12], q[13] --
ry(pi/2) q[12];
rx(pi)   q[12];

ry(pi/2) q[13];
rx(pi)   q[13];

cz q[12], q[13];

ry(pi/2) q[13];
rx(pi)   q[13];

// -- Bell pair 8: q[14], q[15] --
ry(pi/2) q[14];
rx(pi)   q[14];

ry(pi/2) q[15];
rx(pi)   q[15];

cz q[14], q[15];

ry(pi/2) q[15];
rx(pi)   q[15];

// -- Bell pair 9: q[16], q[17] --
ry(pi/2) q[16];
rx(pi)   q[16];

ry(pi/2) q[17];
rx(pi)   q[17];

cz q[16], q[17];

ry(pi/2) q[17];
rx(pi)   q[17];

// -- Bell pair 10: q[18], q[19] --
ry(pi/2) q[18];
rx(pi)   q[18];

ry(pi/2) q[19];
rx(pi)   q[19];

cz q[18], q[19];

ry(pi/2) q[19];
rx(pi)   q[19];

c = measure q;
