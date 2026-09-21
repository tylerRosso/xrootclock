#!/bin/sh
# A reply split across two writes must still be read whole.
#
# Nothing on a stream socket promises that a packet arrives in one read(2). The
# server may write it in pieces, and a client that takes the first short read
# for the whole thing then parses the tail as a fresh packet. The setup prefix
# is the worst place for that: bytes 6-7 carry the length of everything that
# follows, so a prefix read that stops after four bytes makes the client size
# the rest of the handshake from uninitialised memory.
#
# fakex's "split" mode writes every reply as two writes -- the 8-byte setup
# prefix, the 88-byte setup body, and the 32-byte GetInputFocus reply -- which
# puts read_all()'s loop, in x_handshake() and in x_sync(), on the hook.
#
# Pins: a one-shot update against a splitting server still succeeds, with the
# same bytes on the wire as against a normal one.
#
# Two writes are not by themselves two reads, though. Measured here, a client
# that gave up after one read still got the whole prefix in ~98% of runs: the
# server issues its second write long before the woken-up client is scheduled,
# so the halves are back together by the time read(2) returns. Ten rounds of
# plain runs are therefore a weak net, and the second phase below is what
# actually forces the split to survive as far as the client:
#
#   - both processes on ONE cpu, so they cannot run side by side, and
#   - the server at nice 19, so the client it wakes preempts it immediately,
#     between the two writes, instead of waiting for it to finish.
#
# With both, a read_all() that does not loop fails 60 runs out of 60; with only
# the pinning, 3 out of 60; with only the nice, 0 out of 60. The correct program
# passes all of them. The phase is skipped, not failed, where taskset(1) or
# renice(1) cannot do this -- a cpuset that excludes cpu 0, say.

. "${srcdir=.}/tests/init.sh"

start_fakex_ split

# Phase 1: plain rounds, whatever the scheduler does with them.
i=1
while test $i -le 10; do
	returns_ 0 "$XRC" -1 "SPLIT$i" 2> "split$i.err" ||
		{ cat "split$i.err" >&2; fail=1; }
	i=$(( i + 1 ))
done

# The wire is still correct, checked against the literal protocol numbers:
# opcode 18 ChangeProperty, mode 0 Replace, property 39 XA_WM_NAME,
# type 31 XA_STRING, format 8; and opcode 43 GetInputFocus for the sync.
fakex_grep_ '^REQUEST opcode=18 ' || fail=1
prop='^CHANGEPROPERTY mode=0 window=0x[0-9a-f]* property=39 type=31 format=8'
fakex_grep_ "$prop units=6 data=SPLIT1\$" || fail=1
fakex_grep_ '^REQUEST opcode=43 ' || fail=1
fakex_grep_ '^GETINPUTFOCUS$'     || fail=1

# Phase 2: make the short read actually happen.
if command -v taskset > /dev/null 2>&1 && command -v renice > /dev/null 2>&1 &&
	taskset -c 0 true > /dev/null 2>&1 && test -n "$fakex_pid_" &&
	renice -n 19 -p "$fakex_pid_" > /dev/null 2>&1 &&
	taskset -pc 0 "$fakex_pid_" > /dev/null 2>&1
then
	i=1
	while test $i -le 10; do
		returns_ 0 taskset -c 0 "$XRC" -1 "PINNED$i" 2> "pinned$i.err" ||
			{ cat "pinned$i.err" >&2; fail=1; }
		fakex_grep_ "data=PINNED$i\$" || fail=1
		i=$(( i + 1 ))
	done
else
	warn_ "$ME_: cannot pin to one cpu; the short read stayed a coin flip"
fi

Exit $fail
