#!/bin/sh
# Option order, and the dashes that need no escaping.
#
# What it pins:
#   - -i and -1 may be given in either order, in either spelling, and mixed,
#     and every combination performs exactly one update with the given FORMAT;
#   - a FORMAT that merely CONTAINS a dash needs no "--", because only a
#     LEADING dash makes an argument an option;
#   - option parsing stops at the FORMAT: an option written after it is a
#     surplus argument, not an option, and is refused.
#
# Each value is counted, not just grepped for: "both orders wrote it" is two
# lines, and a build where one order silently dropped the format would still
# match a plain grep thanks to the other one.

. "${srcdir=.}/tests/init.sh"

# Every run is bounded. A build that stopped honouring -1 would otherwise hang
# the suite forever instead of failing it.
require_prog_ timeout

# expect_count_ N PATTERN -- assert the log holds exactly N matching lines.
# The grep has to re-run on every poll, so it lives in a function. Passing
# "$(grep -c ...)" straight to retry_ expands it once while retry_'s argument
# list is built, and then compares that one stale number 250 times -- it looks
# like polling and polls nothing.
expect_count_check_ ()
{
	test "$(grep -c -- "$expect_count_pat_" "$FAKEX_LOG")" -eq "$expect_count_n_"
}

expect_count_ ()
{
	expect_count_n_=$1
	expect_count_pat_=$2

	retry_ 5 expect_count_check_ && return 0

	warn_ "$ME_: expected $expect_count_n_ lines matching: $expect_count_pat_"
	cat "$FAKEX_LOG" >&2

	return 1
}

start_fakex_

# Short spellings, both orders.
returns_ 0 timeout 10 "$XRC" -1 -i 5 'ORDER-A' || fail=1
returns_ 0 timeout 10 "$XRC" -i 5 -1 'ORDER-A' || fail=1
expect_count_ 2 'CHANGEPROPERTY .* data=ORDER-A$' || fail=1

# Long spellings, both orders.
returns_ 0 timeout 10 "$XRC" --once --interval 5 'ORDER-B' || fail=1
returns_ 0 timeout 10 "$XRC" --interval 5 --once 'ORDER-B' || fail=1
expect_count_ 2 'CHANGEPROPERTY .* data=ORDER-B$' || fail=1

# Spellings mixed, both orders.
returns_ 0 timeout 10 "$XRC" -1 --interval 5 'ORDER-C' || fail=1
returns_ 0 timeout 10 "$XRC" --interval 5 -1 'ORDER-C' || fail=1
expect_count_ 2 'CHANGEPROPERTY .* data=ORDER-C$' || fail=1

# Six runs, six updates: no order slipped an extra request onto the wire.
expect_count_ 6 '^CHANGEPROPERTY ' || fail=1

# A dash inside the FORMAT is just a character. None of these need "--".
returns_ 0 timeout 10 "$XRC" -1 'up-time' 2> dash.err || fail=1
returns_ 0 timeout 10 "$XRC" -i 5 -1 'temp -5C' 2>> dash.err || fail=1
returns_ 0 timeout 10 "$XRC" -1 '2026-09-17 | -15C | a--b' 2>> dash.err ||
	fail=1

test -s dash.err &&
	{ warn_ 'a FORMAT containing a dash was rejected'; cat dash.err >&2; fail=1; }

fakex_grep_ 'CHANGEPROPERTY .* units=7 data=up-time$'  || fail=1
fakex_grep_ 'CHANGEPROPERTY .* units=8 data=temp -5C$' || fail=1
fakex_grep_ 'CHANGEPROPERTY .* units=24 data=2026-09-17 | -15C | a--b$' ||
	fail=1

# Parsing stops at the FORMAT: what follows it is a surplus argument, whatever
# it looks like.
returns_ 1 timeout 10 "$XRC" -1 'FMT' -i 5 2> late.err || fail=1
grep -q "^xrootclock: unexpected argument '-i'\.\$" late.err || {
	warn_ 'an option after the FORMAT was not refused as surplus'
	cat late.err >&2
	fail=1
}

returns_ 1 timeout 10 "$XRC" 'FMT' --once 2> late2.err || fail=1
grep -q "^xrootclock: unexpected argument '--once'\.\$" late2.err || {
	warn_ 'a long option after the FORMAT was not refused as surplus'
	cat late2.err >&2
	fail=1
}

Exit $fail
