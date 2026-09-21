#!/bin/sh
# An X error coming back from an update must be reported, not swallowed.
#
# ChangeProperty generates no reply, so a request the server dislikes surfaces
# asynchronously as a 32-byte error packet: byte 0 is 0 (X_Error) and byte 1 is
# the error code. It can be picked up either by the post-update drain or by the
# sync round trip on the way out, depending on when it lands; both paths print
# the same line and both must fail the run.
#
# The code asserted here is the literal 9 that fakex sends, not a name -- the
# program prints whatever the server said, and must not mangle it.
#
# Pins: the error code reaches stderr, and the exit status is 1 rather than a
# cheerful 0 on an update that never took effect.

. "${srcdir=.}/tests/init.sh"

start_fakex_ error

returns_ 1 "$XRC" -1 'BOOM' > error.out 2> error.err ||
	{ cat error.err >&2; fail=1; }

grep -q '^xrootclock: the X server returned error code 9\.$' error.err ||
	{ warn_ 'the X error code was not reported'; cat error.err >&2; fail=1; }

test -s error.out && { warn_ 'wrote to stdout'; fail=1; }

# The error was a reaction to a real update, not a refusal to send one.
fakex_grep_ '^REQUEST opcode=18 ' || fail=1
fakex_grep_ 'data=BOOM$'          || fail=1

Exit $fail
