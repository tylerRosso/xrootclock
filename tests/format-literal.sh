#!/bin/sh
# A format with no % in it is copied through byte for byte.
#
# This is the `xrootclock -1 'maintenance mode'` case -- a drop-in for
# `xsetroot -name` with no clock in it at all. What is easy to lose here is
# whitespace: the DEFAULT format is ' %a %m%d%y %I%M ', whose surrounding spaces
# are deliberate padding for the bar, so anything that trims the strftime result
# would quietly change every user's status line. The trailing-space check below
# is anchored with $ for exactly that reason.

. "${srcdir=.}/tests/init.sh"

start_fakex_

# Leading and trailing spaces, interior spaces, and punctuation.
text=' up-to-date: 3 tasks, 0 errors! '
units=$(printf '%s' "$text" | wc -c | tr -d ' ')

test "$units" = 32 ||
	framework_failure_ "expected 32 bytes of test text, got $units"

returns_ 0 "$XRC" -1 "$text" 2> literal.err || fail=1

grep -q '^xrootclock:' literal.err &&
	{ warn_ 'literal format produced a diagnostic'; cat literal.err >&2; fail=1; }

# Byte count and bytes both, and $-anchored so a lost trailing space fails.
fakex_grep_ "units=$units data=$text\$" || fail=1

# Whitespace at each end, spelled out separately from the whole-string check so
# a failure says which end was eaten.
fakex_grep_ 'data= up-to-date' || fail=1
fakex_grep_ '0 errors! $'      || fail=1

# A bare space is a legal one-byte format, and the likeliest thing a trim would
# turn into the empty string.
returns_ 0 "$XRC" -1 ' ' || fail=1
fakex_grep_ 'units=1 data= $' || fail=1

Exit $fail
