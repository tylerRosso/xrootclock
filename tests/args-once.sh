#!/bin/sh
# -1 and --once: one update, then exit.
#
# What it pins:
#   - the two spellings are the same option, down to the request stream they
#     produce;
#   - "once" means EXACTLY one ChangeProperty, counted in the server's log --
#     not "at least one", which a still-looping build would also satisfy;
#   - the program exits by itself, without a signal;
#   - -i is still accepted alongside -1, and is simply never waited on.
#
# -i 1 is deliberate: it is the shortest interval the program accepts, so a
# build that failed to stop would log roughly one line per second and be caught
# by the count. timeout(1) bounds that build instead of hanging the suite.

. "${srcdir=.}/tests/init.sh"

require_prog_ timeout

# count_changeproperty_ EXPECTED WHAT -- wait for the client to be gone, then
# count. The server logs DISCONNECT last, so once that line is there no further
# CHANGEPROPERTY can appear for that run.
count_changeproperty_ ()
{
	fakex_grep_ '^DISCONNECT$' || return 1

	count_actual_=$(grep -c '^CHANGEPROPERTY ' "$FAKEX_LOG")

	if test "$count_actual_" -ne "$1"; then
		warn_ "$ME_: $2: expected $1 CHANGEPROPERTY, got $count_actual_"
		cat "$FAKEX_LOG" >&2

		return 1
	fi

	return 0
}

# The display number start_fakex_ settles on is not part of what is being
# tested, so it is normalised away before two runs are compared.
normalize_log_ ()
{
	sed -e 's/^LISTENING .*/LISTENING/' "$FAKEX_LOG" > "$1"
}

start_fakex_

returns_ 0 timeout 10 "$XRC" -i 1 -1 'ONCE-SHORT' || fail=1
fakex_grep_ 'CHANGEPROPERTY .* data=ONCE-SHORT$'  || fail=1
count_changeproperty_ 1 '-1'                      || fail=1

stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" -i 1 --once 'ONCE-LONG' || fail=1
fakex_grep_ 'CHANGEPROPERTY .* data=ONCE-LONG$'     || fail=1
count_changeproperty_ 1 '--once'                    || fail=1

# Interchangeable: given the same text, the two spellings must put the same
# requests on the wire, in the same order.
stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" -1 'SAME' || fail=1
fakex_grep_ '^DISCONNECT$'             || fail=1
normalize_log_ short.log

stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" --once 'SAME' || fail=1
fakex_grep_ '^DISCONNECT$'                 || fail=1
normalize_log_ long.log

compare short.log long.log || fail=1

Exit $fail
