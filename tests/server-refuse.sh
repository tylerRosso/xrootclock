#!/bin/sh
# A server that rejects the connection setup: the reason must be relayed.
#
# The X11 setup reply carries the refusal as a counted string -- byte 0 of the
# 8-byte prefix is 0 (Failed), byte 1 is the reason length, and the text follows
# in the additional data. Reporting only "refused" throws away the one thing
# that says why: "no protocol specified", "Authorization required, but no
# authorization protocol specified", and so on.
#
# Pins: exit status exactly 1, and the server's own reason relayed verbatim.
# Also pins that the program does not retry: a refused setup is final, and a
# reconnect loop would hammer the server instead of failing.

. "${srcdir=.}/tests/init.sh"

start_fakex_ refuse

# The redirection covers returns_ itself, so its diagnostic lands in
# refuse.err too: print the file rather than lose the reason.
returns_ 1 "$XRC" -1 'NOPE' > refuse.out 2> refuse.err ||
	{ cat refuse.err >&2; fail=1; }

expected='^xrootclock: the X server refused the connection:'
grep -q "$expected fakex refuses this connection\$" refuse.err ||
	{ warn_ 'the server reason was not relayed'; cat refuse.err >&2; fail=1; }

test -s refuse.out && { warn_ 'wrote to stdout'; fail=1; }

# The handshake was attempted, with no cookie (XAUTHORITY points at a file that
# does not exist), and it was attempted exactly once -- a refusal is final, and
# retrying it in a loop would be worse than failing.
#
# Not asserted with fakex_not_grep_ '^REQUEST ': fakex stops reading after it
# refuses, so it could not log a stray request even if one were sent. Counting
# the connections is a check that can actually fail.
fakex_grep_ '^SETUP authname=0 authdata=0$' || fail=1

setups_=$(grep -c '^SETUP ' "$FAKEX_LOG")

test "$setups_" -eq 1 ||
	{ warn_ "connected $setups_ times, expected 1"; fail=1; }

Exit $fail
