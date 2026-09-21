#!/bin/sh
# A signal must not cost the last update.
#
# Regression, same one once-write-lands.sh pins for -1: ChangeProperty has no
# reply, and the server discards a disconnecting client's unread input, so
# exiting straight out of the signal handler's path loses whatever was last
# written. x_sync() (GetInputFocus, opcode 43) must therefore sit on the SIGNAL
# exit path too, not only on the -1 path.
#
# So the last two things the server sees, in order, are the final
# CHANGEPROPERTY and then the GETINPUTFOCUS that proves it was applied.
#
# The count is asserted as well: EXACTLY one round trip, no matter how many
# updates went out. Syncing per update would pass the ordering check while
# quietly adding two syscalls to the steady-state loop, which is the one thing
# the loop is not allowed to do.

. "${srcdir=.}/tests/init.sh"

updates_ () { grep -c '^CHANGEPROPERTY ' "$FAKEX_LOG" 2> /dev/null; }

have_updates_ () { test "$(updates_)" -ge "$1"; }

start_fakex_

"$XRC" -i 1 'SYNCTAG' & pid=$!

if ! retry_ 20 have_updates_ 2; then
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	fail_ 'the clock did not reach a second update'
fi

kill -TERM "$pid"

fakex_grep_ '^DISCONNECT$' || {
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	fail_ 'the program did not exit after SIGTERM'
}

wait "$pid"
status=$?

test "$status" -eq 0 || { warn_ "$ME_: expected exit 0, got $status"; fail=1; }

# The protocol traffic, in order, with the arguments stripped.
sed -n -e 's/^\(CHANGEPROPERTY\) .*/\1/p' \
	-e 's/^\(GETINPUTFOCUS\)$/\1/p' "$FAKEX_LOG" > events.txt

last=$(tail -1 events.txt)

test "$last" = 'GETINPUTFOCUS' || {
	warn_ "$ME_: the run ended with '$last', not the GetInputFocus round trip:"
	cat "$FAKEX_LOG" >&2
	fail=1
}

syncs=$(grep -c '^GETINPUTFOCUS$' events.txt)

test "$syncs" -eq 1 || {
	warn_ "$ME_: expected exactly 1 GetInputFocus round trip, got $syncs"
	cat "$FAKEX_LOG" >&2
	fail=1
}

# 43 is the literal opcode from the X11 spec, not the program's own macro.
fakex_grep_ '^REQUEST opcode=43 length=1$' || fail=1

Exit $fail
