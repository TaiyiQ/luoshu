// cx;cx = I via decomposition h.cz.h.h.cz.h - the h's split the czs
// naturally, no pair-split involved; both pulses must still fire.
OPENQASM 3.0;
qubit[2] q;
bit[2] c;
cx q[0], q[1];
cx q[0], q[1];
c = measure q;
