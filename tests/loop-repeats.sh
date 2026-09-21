#!/bin/sh
# The update loop keeps going: -i 1 must produce update after update.
#
# Asserted against what the SERVER received, not against the program staying
# alive -- a program that writes once and then sleeps forever is also still
# running, and `exit 0` proves nothing here (see once-write-lands.sh).
#
# The three values are also required to be distinct. A loop that ticks but
# re-renders a frozen time would still emit three ChangeProperty requests, and
# with %S at a one-second interval consecutive updates can never repeat.

. "${srcdir=.}/tests/init.sh"

updates_ () { grep -c '^CHANGEPROPERTY ' "$FAKEX_LOG" 2> /dev/null; }

have_updates_ () { test "$(updates_)" -ge "$1"; }

start_fakex_

"$XRC" -i 1 '%S' & pid=$!

if ! retry_ 20 have_updates_ 3; then
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	warn_ "--- $FAKEX_LOG ---"
	cat "$FAKEX_LOG" >&2
	fail_ "-i 1 produced $(updates_) updates in 20s, wanted at least 3"
fi

kill -TERM "$pid"

# Bound the wait: a build that ignores the signal must fail the test rather
# than hang the whole suite.
fakex_grep_ '^DISCONNECT$' || {
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	fail_ 'the program did not exit after SIGTERM'
}

wait "$pid"
status=$?

test "$status" -eq 0 || { warn_ "$ME_: expected exit 0, got $status"; fail=1; }

test "$(updates_)" -ge 3 ||
	{ warn_ "$ME_: lost updates after the kill"; fail=1; }

sed -n 's/^CHANGEPROPERTY .*data=\(.*\)$/\1/p' "$FAKEX_LOG" | head -3 > seen.txt

test "$(sort -u seen.txt | wc -l)" -eq 3 || {
	warn_ "$ME_: the first three updates were not three distinct seconds:"
	cat seen.txt >&2
	fail=1
}

Exit $fail
