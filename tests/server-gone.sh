#!/bin/sh
# The server died and left its socket behind: diagnose it, do not crash.
#
# An X server that is killed without cleanup leaves /tmp/.X11-unix/X<n> in the
# filesystem. The path exists, so connect(2) fails with ECONNREFUSED rather than
# ENOENT -- the every-day "X died and my status bar did not notice" case, and a
# different errno from the one server-absent.sh pins.
#
# Pins: exit status exactly 1 (not 139 from a crash, not 0), and a diagnostic
# naming the socket path and the real errno text.

. "${srcdir=.}/tests/init.sh"

gone_socket_=

# The stale socket lives outside the test's temporary directory.
cleanup_ ()
{
	test -n "$gone_socket_" && rm -f "$gone_socket_"

	:
}

start_fakex_ ok

gone_socket_="/tmp/.X11-unix/X${DISPLAY#:}"

test -S "$gone_socket_" ||
	framework_failure_ "fakex left no socket at $gone_socket_"

# SIGKILL, not SIGTERM: fakex unlinks its socket when it shuts down cleanly, and
# the stale socket is the whole point. wait(1) reaps it, so by the time the
# program runs the listener is definitely gone -- no sleep-and-hope.
test -n "$fakex_pid_" || framework_failure_ 'fakex pid unknown'

kill -9 "$fakex_pid_" 2> /dev/null
wait "$fakex_pid_" 2> /dev/null
fakex_pid_=

test -S "$gone_socket_" || skip_ 'the killed server left no socket behind'

returns_ 1 "$XRC" -1 'ORPHANED' > gone.out 2> gone.err ||
	{ cat gone.err >&2; fail=1; }

expected="^xrootclock: cannot connect to '$gone_socket_':"
grep -q "$expected Connection refused\$" gone.err || {
	warn_ 'no cannot-connect diagnostic for a dead server'
	cat gone.err >&2
	fail=1
}

test -s gone.out && { warn_ 'wrote to stdout'; fail=1; }

Exit $fail
