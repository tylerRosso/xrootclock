#!/bin/sh
# No server at all: fail immediately, with the path in the message.
#
# init.sh leaves DISPLAY at :9999 precisely so that a test which forgets to
# start fakex cannot wander onto the real session, so this test starts nothing.
#
# Pins: the socket path derived from DISPLAY (/tmp/.X11-unix/X<number>, the X11
# convention, not something invented), the strerror() text for the failure, and
# exit status exactly 1 -- not a crash, not a hang, not a silent success.

. "${srcdir=.}/tests/init.sh"

test -e /tmp/.X11-unix/X9999 &&
	skip_ 'something is serving display :9999'

returns_ 1 "$XRC" -1 'UNREACHABLE' > absent.out 2> absent.err ||
	{ cat absent.err >&2; fail=1; }

expected="^xrootclock: cannot connect to '/tmp/.X11-unix/X9999':"
grep -q "$expected No such file or directory\$" absent.err ||
	{ warn_ 'no usable cannot-connect diagnostic'; cat absent.err >&2; fail=1; }

test -s absent.out && { warn_ 'wrote to stdout'; fail=1; }

# The looping mode must give up at startup too, rather than spinning against a
# display that will never appear. Bounded, since the failure mode is a hang.
if command -v timeout > /dev/null 2>&1; then
	returns_ 1 timeout 10 "$XRC" -i 1 'UNREACHABLE' > loop.out 2> loop.err ||
		{ cat loop.err >&2; fail=1; }
	compare absent.err loop.err || fail=1
fi

Exit $fail
