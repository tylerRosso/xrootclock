#!/bin/sh
# Every DISPLAY that parse_display() must reject, and the exact message for
# each.
#
# What it pins:
#   - a rejected DISPLAY exits 1, never 0 and never a signal (returns_ asserts
#     the exact status, so a crash here is a failure, not a pass),
#   - which of the four diagnostics each malformed class gets. The classes are
#     distinguishable on purpose: "not set", "malformed DISPLAY" (no colon),
#     "only local displays" (a host part) and "malformed display number".
#     Matching the whole stderr, not a substring, is what keeps one class from
#     silently collapsing into another,
#   - the display-number buffer boundary. display_number[] holds 16 bytes, so
#     15 digits must be accepted and 16 must be rejected -- and the accepted one
#     has to reach the socket path verbatim. An off-by-one in either direction
#     moves exactly one of these two cases.
#
# Nothing here should ever touch a socket: the diagnosis happens before connect.

. "${srcdir=.}/tests/init.sh"

# check_ MESSAGE -- run with the DISPLAY currently in the environment and assert
# exit 1 with exactly MESSAGE, and nothing else, on stderr.
check_ ()
{
	printf '%s\n' "$1" > expected.err

	returns_ 1 "$XRC" -1 'IGNORED' 2> actual.err || fail=1
	compare expected.err actual.err || fail=1
}

unset DISPLAY
check_ "xrootclock: DISPLAY is not set."

DISPLAY=''
export DISPLAY
check_ "xrootclock: DISPLAY is not set."

DISPLAY='nocolon'
check_ "xrootclock: malformed DISPLAY 'nocolon', expected something like ':0'."

DISPLAY='unix'
check_ "xrootclock: malformed DISPLAY 'unix', expected something like ':0'."

DISPLAY=':'
check_ "xrootclock: malformed display number in ':'."

DISPLAY=':.0'
check_ "xrootclock: malformed display number in ':.0'."

DISPLAY=':abc'
check_ "xrootclock: malformed display number in ':abc'."

DISPLAY=':-1'
check_ "xrootclock: malformed display number in ':-1'."

DISPLAY=':0abc'
check_ "xrootclock: malformed display number in ':0abc'."

# 16 digits: one too many for display_number[16] once the terminator is counted.
DISPLAY=':1234567890123456'
check_ "xrootclock: malformed display number in ':1234567890123456'."

DISPLAY='host:0'
check_ "xrootclock: only local displays are supported, got 'host:0'."

DISPLAY='1.2.3.4:0'
check_ "xrootclock: only local displays are supported, got '1.2.3.4:0'."

DISPLAY='localhost:0.0'
check_ "xrootclock: only local displays are supported, got 'localhost:0.0'."

# The other side of the buffer boundary: 15 digits is a legal display number, so
# this must get past parsing and fail on the socket instead, with the number
# passed through to the path unchanged.
DISPLAY=':123456789012345'
returns_ 1 "$XRC" -1 'IGNORED' 2> long.err || fail=1
grep -q "cannot connect to '/tmp/.X11-unix/X123456789012345'" long.err ||
	{ warn_ '15 digits did not reach the socket path'; cat long.err >&2; fail=1; }

Exit $fail
