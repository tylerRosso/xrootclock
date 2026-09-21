#!/bin/sh
# The specifiers musl DOES support must all render, and render correctly.
#
# The bugs in this area were both about strftime returning 0, so the guard that
# catches that sits directly on the happy path. This pins the other side of it:
# an ordinary format must still reach the wire, and must carry the real time.
#
# Correctness is checked against date(1) rather than against a hardcoded
# string. The clock can tick between the two programs, so the value is read
# BEFORE and AFTER the run and either one is accepted -- at most one boundary
# can fall in that gap, so this is exact, not approximate, and it never flakes.

. "${srcdir=.}/tests/init.sh"

require_prog_ date

start_fakex_

# init.sh pins TZ=UTC0 and LC_ALL=C, so date and xrootclock agree on the
# timezone and on the C-locale %a/%b names.
format='%Y-%m-%d %H:%M %a %b %j %%'

before=$(date +"$format") || framework_failure_ 'date failed'
returns_ 0 "$XRC" -1 "$format" 2> valid.err || fail=1
after=$(date +"$format") || framework_failure_ 'date failed'

grep -q '^xrootclock:' valid.err &&
	{ warn_ 'valid format produced a diagnostic'; cat valid.err >&2; fail=1; }

if grep -q -- "data=$before\$" "$FAKEX_LOG" ||
	grep -q -- "data=$after\$" "$FAKEX_LOG"; then
	:
else
	warn_ "expected data=$before (or data=$after) in $FAKEX_LOG"
	cat "$FAKEX_LOG" >&2
	fail=1
fi

# Each specifier on its own, so a single broken one is named rather than
# hidden inside the combined string. The literal tag makes each run's line
# findable in the shared log, and requiring at least one byte after it is what
# proves the conversion actually expanded to something.
n=0
for specifier in '%Y' '%m' '%d' '%H' '%M' '%S' '%a' '%b' '%j' '%%'; do
	n=$(( n + 1 ))

	returns_ 0 "$XRC" -1 "t$n:$specifier" 2> one.err || fail=1

	grep -q '^xrootclock:' one.err &&
		{ warn_ "$specifier produced a diagnostic"; cat one.err >&2; fail=1; }

	fakex_grep_ "data=t$n:..*\$" ||
		{ warn_ "$specifier produced nothing"; fail=1; }
done

# %a and %b are the C-locale abbreviations, three letters, capitalised.
returns_ 0 "$XRC" -1 '%a/%b' || fail=1
fakex_grep_ 'data=[A-Z][a-z][a-z]/[A-Z][a-z][a-z]$' || fail=1

# %% is one literal percent, not a dropped conversion.
returns_ 0 "$XRC" -1 'p%%q' || fail=1
fakex_grep_ 'units=3 data=p%q$' || fail=1

Exit $fail
