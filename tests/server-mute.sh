#!/bin/sh
# A server that accepts and then never answers wedges the program. Forever.
#
# This test documents a genuine weakness, not a desirable behaviour.
#
# x_sync() writes GetInputFocus and blocks in read(2) for the 32-byte reply,
# which is deliberate and load-bearing -- it is what makes a one-shot update
# actually land (see once-write-lands.sh). But there is no deadline on that
# read. A server that completes the handshake, takes the update and then goes
# quiet leaves xrootclock blocked on its exit path with the update already sent
# and nothing left to do.
#
# SIGTERM does not get it out either: read_all() retries on EINTR, so the
# handler's keep_running = 0 is never looked at again, and the process sits
# there. A plain `timeout 2` hangs along with it, waiting for a child that will
# not die -- which is why this test must use the kill escalation.
#
# A poll(2) with a deadline around the sync, or skipping the EINTR retry once
# keep_running is clear, would fix it. Nothing in the program promises either
# today, so what is pinned here is what actually happens:
#
#   - the update and the sync round trip both reach the server, then
#   - the process survives SIGTERM, and only SIGKILL ends it.
#
# `timeout -k 1 2` sends SIGTERM at 2s and SIGKILL at 3s. GNU timeout reports
# 137 (128 + SIGKILL) when the kill was needed and 124 when the command died on
# the SIGTERM, so 137 is the assertion that says "SIGTERM was ignored".
#
# If this ever fails with 124, the weakness has been fixed -- change the
# expected status and delete the paragraphs above. If it fails with 0, the sync
# has stopped waiting for its reply, which is the regression once-write-lands.sh
# exists for.

. "${srcdir=.}/tests/init.sh"

require_prog_ timeout

start_fakex_ mute

# The redirection covers returns_ itself, so a wrong status is explained in
# mute.err rather than on the test's own stderr: print it.
returns_ 137 timeout -k 1 2 "$XRC" -1 'MUTED' > mute.out 2> mute.err ||
	{ cat mute.err >&2; fail=1; }

# It really did get as far as the sync: the property was written and the round
# trip went out (opcode 43, GetInputFocus) before it stalled.
fakex_grep_ 'CHANGEPROPERTY .* data=MUTED$' || fail=1
fakex_grep_ '^REQUEST opcode=43 '           || fail=1
fakex_grep_ '^GETINPUTFOCUS$'               || fail=1

# Blocked in read(2), not spinning and not complaining: the program itself said
# nothing. Matched on the "xrootclock:" prefix rather than on mute.err being
# empty, because the shell writes its own "Killed" notice into the redirection
# when it reaps a SIGKILLed child.
test -s mute.out &&
	{ warn_ 'wrote to stdout while blocked'; cat mute.out >&2; fail=1; }
grep -q '^xrootclock:' mute.err &&
	{ warn_ 'diagnosed something while blocked'; cat mute.err >&2; fail=1; }

Exit $fail
