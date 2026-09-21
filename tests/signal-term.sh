#!/bin/sh
# SIGTERM ends the run cleanly: the program exits 0, it is not killed.
#
# The distinction is the whole point and the shell makes it visible: `wait`
# reports 128+signal (143) for a process that DIED from SIGTERM, and the
# program's own status for one that caught it and returned. Asserting "exit 0"
# is only meaningful because 143 is the failure it rules out.
#
# The interval is long on purpose, so the program is provably parked in
# clock_nanosleep when the signal lands -- the handler has to break the sleep,
# not merely be noticed at the top of the next iteration.

. "${srcdir=.}/tests/init.sh"

start_fakex_

"$XRC" -i 600 'TERMTAG' & pid=$!

# Do not signal before the handlers are installed: the first update is the
# proof that startup is complete.
fakex_grep_ 'CHANGEPROPERTY .* data=TERMTAG$' || {
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	fail_ 'the first update never arrived'
}

kill -TERM "$pid"

# Bound the wait, so a build that ignores SIGTERM fails instead of hanging the
# suite for ever. The server logs DISCONNECT when the client's socket closes,
# which happens whether the program exits or is killed.
fakex_grep_ '^DISCONNECT$' || {
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	fail_ 'the program did not exit after SIGTERM'
}

wait "$pid"
status=$?

case $status in
	0)   ;;
	143) warn_ "$ME_: killed BY SIGTERM (128+15) instead of handling it"; fail=1 ;;
	*)   warn_ "$ME_: expected exit 0 after SIGTERM, got $status";        fail=1 ;;
esac

Exit $fail
