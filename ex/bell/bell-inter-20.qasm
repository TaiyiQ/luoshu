OPENQASM 3.0;
include "stdgates.inc";

qubit[20] q;
bit[20] c;

// -- Bell link 1: q[0], q[1] --
ry(pi/2) q[0];
rx(pi)   q[0];

ry(pi/2) q[1];
rx(pi)   q[1];

cz q[0], q[1];

ry(pi/2) q[1];
rx(pi)   q[1];

// -- Bell link 2: q[1], q[2] --
ry(pi/2) q[1];
rx(pi)   q[1];

ry(pi/2) q[2];
rx(pi)   q[2];

cz q[1], q[2];

ry(pi/2) q[2];
rx(pi)   q[2];

// -- Bell link 3: q[2], q[3] --
ry(pi/2) q[2];
rx(pi)   q[2];

ry(pi/2) q[3];
rx(pi)   q[3];

cz q[2], q[3];

ry(pi/2) q[3];
rx(pi)   q[3];

// -- Bell link 4: q[3], q[4] --
ry(pi/2) q[3];
rx(pi)   q[3];

ry(pi/2) q[4];
rx(pi)   q[4];

cz q[3], q[4];

ry(pi/2) q[4];
rx(pi)   q[4];

// -- Bell link 5: q[4], q[5] --
ry(pi/2) q[4];
rx(pi)   q[4];

ry(pi/2) q[5];
rx(pi)   q[5];

cz q[4], q[5];

ry(pi/2) q[5];
rx(pi)   q[5];

// -- Bell link 6: q[5], q[6] --
ry(pi/2) q[5];
rx(pi)   q[5];

ry(pi/2) q[6];
rx(pi)   q[6];

cz q[5], q[6];

ry(pi/2) q[6];
rx(pi)   q[6];

// -- Bell link 7: q[6], q[7] --
ry(pi/2) q[6];
rx(pi)   q[6];

ry(pi/2) q[7];
rx(pi)   q[7];

cz q[6], q[7];

ry(pi/2) q[7];
rx(pi)   q[7];

// -- Bell link 8: q[7], q[8] --
ry(pi/2) q[7];
rx(pi)   q[7];

ry(pi/2) q[8];
rx(pi)   q[8];

cz q[7], q[8];

ry(pi/2) q[8];
rx(pi)   q[8];

// -- Bell link 9: q[8], q[9] --
ry(pi/2) q[8];
rx(pi)   q[8];

ry(pi/2) q[9];
rx(pi)   q[9];

cz q[8], q[9];

ry(pi/2) q[9];
rx(pi)   q[9];

// -- Bell link 10: q[9], q[10] --
ry(pi/2) q[9];
rx(pi)   q[9];

ry(pi/2) q[10];
rx(pi)   q[10];

cz q[9], q[10];

ry(pi/2) q[10];
rx(pi)   q[10];

// -- Bell link 11: q[10], q[11] --
ry(pi/2) q[10];
rx(pi)   q[10];

ry(pi/2) q[11];
rx(pi)   q[11];

cz q[10], q[11];

ry(pi/2) q[11];
rx(pi)   q[11];

// -- Bell link 12: q[11], q[12] --
ry(pi/2) q[11];
rx(pi)   q[11];

ry(pi/2) q[12];
rx(pi)   q[12];

cz q[11], q[12];

ry(pi/2) q[12];
rx(pi)   q[12];

// -- Bell link 13: q[12], q[13] --
ry(pi/2) q[12];
rx(pi)   q[12];

ry(pi/2) q[13];
rx(pi)   q[13];

cz q[12], q[13];

ry(pi/2) q[13];
rx(pi)   q[13];

// -- Bell link 14: q[13], q[14] --
ry(pi/2) q[13];
rx(pi)   q[13];

ry(pi/2) q[14];
rx(pi)   q[14];

cz q[13], q[14];

ry(pi/2) q[14];
rx(pi)   q[14];

// -- Bell link 15: q[14], q[15] --
ry(pi/2) q[14];
rx(pi)   q[14];

ry(pi/2) q[15];
rx(pi)   q[15];

cz q[14], q[15];

ry(pi/2) q[15];
rx(pi)   q[15];

// -- Bell link 16: q[15], q[16] --
ry(pi/2) q[15];
rx(pi)   q[15];

ry(pi/2) q[16];
rx(pi)   q[16];

cz q[15], q[16];

ry(pi/2) q[16];
rx(pi)   q[16];

// -- Bell link 17: q[16], q[17] --
ry(pi/2) q[16];
rx(pi)   q[16];

ry(pi/2) q[17];
rx(pi)   q[17];

cz q[16], q[17];

ry(pi/2) q[17];
rx(pi)   q[17];

// -- Bell link 18: q[17], q[18] --
ry(pi/2) q[17];
rx(pi)   q[17];

ry(pi/2) q[18];
rx(pi)   q[18];

cz q[17], q[18];

ry(pi/2) q[18];
rx(pi)   q[18];

// -- Bell link 19: q[18], q[19] --
ry(pi/2) q[18];
rx(pi)   q[18];

ry(pi/2) q[19];
rx(pi)   q[19];

cz q[18], q[19];

ry(pi/2) q[19];
rx(pi)   q[19];

c = measure q;
