#!/bin/sh
# -u / --upper: upper-case the strftime result.
#
# What it pins:
#   - the two spellings are the same option, down to the request stream they
#     produce;
#   - it really does upper-case: a lower-case literal comes back upper-cased,
#     and so does the %a weekday name -- "Wed" must become "WED", which is the
#     entire reason the flag exists (musl's strftime has no GNU %^);
#   - WITHOUT -u nothing is upper-cased. That negative half is what makes the
#     positive half mean anything: against a build that upper-cased
#     unconditionally every check above would still pass;
#   - it composes with -1, -i and "--" in any order;
#   - digits, spaces and punctuation are untouched, and the byte LENGTH does
#     not change -- units= is identical with and without the flag;
#   - the exact shape the flag exists to reproduce, " THU 091726 0859 ", is
#     pinned as a pattern rather than as a wall-clock value;
#   - the usage text advertises -u.
#
# UTF-8 safety is the other half of this option and has a test of its own,
# format-upper-utf8. The error paths are in format-upper-errors.

. "${srcdir=.}/tests/init.sh"

# Every run is bounded. A build that stopped honouring -1 would otherwise hang
# the suite forever instead of failing it.
require_prog_ timeout date

# capture_data_ FILE -- the "units=N data=..." tail of every CHANGEPROPERTY
# line logged so far. Compared as a file rather than grepped for, because the
# text under test is full of regular-expression metacharacters and must be
# matched as bytes, not as a pattern.
#
# fakex flushes after every request it serves, and it serves ChangeProperty
# before the GetInputFocus reply that lets the client exit, so a line is always
# on disk by the time the run returns.
capture_data_ ()
{
	sed -n 's/^CHANGEPROPERTY .*format=8 //p' "$FAKEX_LOG" > "$1" ||
		framework_failure_ "cannot read $FAKEX_LOG"
}

# The display number start_fakex_ settles on is not part of what is being
# tested, so it is normalised away before two runs are compared.
normalize_log_ ()
{
	sed -e 's/^LISTENING .*/LISTENING/' "$FAKEX_LOG" > "$1"
}

# expect_count_ N PATTERN -- assert the log holds exactly N matching lines.
# The grep has to re-run on every poll, so it lives in a function: passing
# "$(grep -c ...)" straight to retry_ expands it once and then compares that
# one stale number 250 times.
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

# ------------------------------------------------------------------- usage

returns_ 0 "$XRC" -h > help.out 2>&1 || fail=1

grep -q '^Usage: xrootclock .*\[-u\]' help.out ||
	{ warn_ 'the usage line does not mention -u'; cat help.out >&2; fail=1; }

grep -q '^  -u  *[^ ]' help.out ||
	{ warn_ 'the option list has no -u entry'; cat help.out >&2; fail=1; }

grep -q '^  -u .*upper' help.out ||
	{ warn_ 'the -u entry does not say what it does'; cat help.out >&2; fail=1; }

# ------------------------------------------------- it upper-cases, and only
#                                                    when it is asked to

start_fakex_

returns_ 0 timeout 10 "$XRC" -1 -u 'upper one' 2> upper.err || fail=1
test -s upper.err && { warn_ '-u wrote to stderr'; cat upper.err >&2; fail=1; }
fakex_grep_ 'CHANGEPROPERTY .* units=9 data=UPPER ONE$' || fail=1

returns_ 0 timeout 10 "$XRC" -1 --upper 'upper two' 2> upper2.err || fail=1
test -s upper2.err &&
	{ warn_ '--upper wrote to stderr'; cat upper2.err >&2; fail=1; }
fakex_grep_ 'CHANGEPROPERTY .* units=9 data=UPPER TWO$' || fail=1

# The negative case. Same program, same format, no flag: the bytes must come
# back exactly as they went in.
returns_ 0 timeout 10 "$XRC" -1 'plain three' 2> plain.err || fail=1
test -s plain.err &&
	{ warn_ 'a plain run wrote to stderr'; cat plain.err >&2; fail=1; }
fakex_grep_    'CHANGEPROPERTY .* units=11 data=plain three$' || fail=1
fakex_not_grep_ 'data=PLAIN THREE$' || fail=1

# Already upper-case input is a fixed point, and mixed case is levelled.
returns_ 0 timeout 10 "$XRC" -1 -u 'MiXeD Case' || fail=1
fakex_grep_ 'CHANGEPROPERTY .* units=10 data=MIXED CASE$' || fail=1

# ------------------------------------------------ the same option, twice over

# Interchangeable: given the same text, the two spellings must put the same
# requests on the wire, in the same order.
stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" -1 -u 'same text' || fail=1
fakex_grep_ '^DISCONNECT$' || fail=1
normalize_log_ short.log

stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" -1 --upper 'same text' || fail=1
fakex_grep_ '^DISCONNECT$' || fail=1
normalize_log_ long.log

compare short.log long.log || fail=1

# ---------------------------------------------------------- the weekday name

# The motivating case: %a renders "Wed" and the bar wants "WED". Checked
# against date(1) rather than a hardcoded name; the day can turn over between
# the two programs, so the value is read BEFORE and AFTER the run and either is
# accepted. At most one midnight can fall in that gap, so this is exact rather
# than approximate, and it cannot flake.
stop_fakex_
start_fakex_

before=$(date +%a | tr 'a-z' 'A-Z') || framework_failure_ 'date failed'
returns_ 0 timeout 10 "$XRC" -1 -u 'w:%a' 2> day.err || fail=1
after=$(date +%a | tr 'a-z' 'A-Z') || framework_failure_ 'date failed'

test -s day.err && { warn_ '-u %a wrote to stderr'; cat day.err >&2; fail=1; }

if grep -q -- "data=W:$before\$" "$FAKEX_LOG" ||
	grep -q -- "data=W:$after\$" "$FAKEX_LOG"; then
	:
else
	warn_ "$ME_: expected data=W:$before (or data=W:$after) in $FAKEX_LOG"
	cat "$FAKEX_LOG" >&2
	fail=1
fi

# Shape, independent of what day it is: three upper-case letters with -u,
# capitalised-then-lower-case without it. The second half is what proves the
# first is the flag's doing and not the C locale's.
fakex_grep_ 'units=5 data=W:[A-Z][A-Z][A-Z]$' || fail=1

returns_ 0 timeout 10 "$XRC" -1 'p:%a' || fail=1
fakex_grep_    'units=5 data=p:[A-Z][a-z][a-z]$' || fail=1
fakex_not_grep_ 'data=P:' || fail=1

# --------------------------------------------------------- option composition

stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" -1 -u        'combo a' || fail=1
returns_ 0 timeout 10 "$XRC" -u -1        'combo b' || fail=1
returns_ 0 timeout 10 "$XRC" -i 5 -u -1   'combo c' || fail=1
returns_ 0 timeout 10 "$XRC" -u -i 5 -1   'combo d' || fail=1
returns_ 0 timeout 10 "$XRC" -1 -i 5 -u   'combo e' || fail=1
returns_ 0 timeout 10 "$XRC" --once --upper --interval 5 'combo f' || fail=1
returns_ 0 timeout 10 "$XRC" --upper --interval 5 --once 'combo g' || fail=1

# Seven runs, seven upper-cased updates: no order dropped the flag, and none
# slipped an extra request onto the wire. Counted first so the log is known to
# be complete, then named one by one so a failure says which order broke.
expect_count_ 7 'CHANGEPROPERTY .* units=7 data=COMBO [A-G]$' || fail=1

for tag in A B C D E F G; do
	grep -q "CHANGEPROPERTY .* units=7 data=COMBO $tag\$" "$FAKEX_LOG" ||
		{ warn_ "$ME_: combo $tag did not arrive upper-cased"; fail=1; }
done

# "--" still ends the options, and -u still applies to what follows it.
returns_ 0 timeout 10 "$XRC" -1 -u -- '-leading dash' 2> dash.err || fail=1
test -s dash.err &&
	{ warn_ '-u with a leading-dash format complained'; cat dash.err >&2; fail=1; }
fakex_grep_ 'CHANGEPROPERTY .* units=13 data=-LEADING DASH$' || fail=1

# -u after the FORMAT is a surplus argument, not a late option: parsing stops
# at the format.
returns_ 1 timeout 10 "$XRC" -1 'fmt' -u 2> late.err || fail=1
grep -q "^xrootclock: unexpected argument '-u'\.\$" late.err || {
	warn_ '-u after the FORMAT was not refused as surplus'
	cat late.err >&2
	fail=1
}

# ------------------------------------ everything that is not a lower-case ASCII
#                                      letter, and the length that must not move

# Digits, spaces and punctuation, several of which are regular-expression
# metacharacters -- hence the byte-for-byte file comparison.
stop_fakex_
start_fakex_

text='| mix 09/17 a-b_c [x] 3.14 ok! |'
units=$(printf '%s' "$text" | wc -c | tr -d ' ')

test "$units" = 32 ||
	framework_failure_ "expected 32 bytes of test text, got $units"

returns_ 0 timeout 10 "$XRC" -1 "$text" 2> mix.err || fail=1
returns_ 0 timeout 10 "$XRC" -1 -u "$text" 2>> mix.err || fail=1

test -s mix.err &&
	{ warn_ 'the punctuation run wrote to stderr'; cat mix.err >&2; fail=1; }

# Both runs, in order. Identical units= on both lines is the length assertion:
# upper-casing must not add or drop a byte.
cat > mix.exp <<'EOF'
units=32 data=| mix 09/17 a-b_c [x] 3.14 ok! |
units=32 data=| MIX 09/17 A-B_C [X] 3.14 OK! |
EOF

capture_data_ mix.out
compare mix.exp mix.out || fail=1

# ------------------------------------------------------------- the real thing

# What the flag was added for: the same shape the user's Go status bar prints,
# e.g. " THU 091726 0859 ". Pinned as a pattern, never as a wall-clock value.
stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" -1 -u ' %a %m%d%y %I%M ' 2> bar.err || fail=1
test -s bar.err &&
	{ warn_ 'the status-bar format complained'; cat bar.err >&2; fail=1; }

upper='[A-Z][A-Z][A-Z] [0-9][0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]'
fakex_grep_ "CHANGEPROPERTY .* units=17 data= $upper \$" ||
	{ warn_ 'the -u status line is not of the form " THU 091726 0859 "'; fail=1; }

# Same format without the flag: same length, same digits, and the weekday in
# the mixed case the bar could not use.
returns_ 0 timeout 10 "$XRC" -1 ' %a %m%d%y %I%M ' || fail=1
mixed='[A-Z][a-z][a-z] [0-9][0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]'
fakex_grep_ "CHANGEPROPERTY .* units=17 data= $mixed \$" || fail=1

Exit $fail
