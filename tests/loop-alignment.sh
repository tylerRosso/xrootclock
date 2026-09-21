#!/bin/sh
# Updates land on wall-clock boundaries, not on "whenever the last one
# finished".
#
# The loop sleeps on an ABSOLUTE deadline -- the next multiple of the interval
# on CLOCK_REALTIME -- so with -i 2 every update after the first falls on an
# even second and with -i 3 on a multiple of three. A relative sleep would give
# the same NUMBER of updates while drifting one round trip per iteration, so
# loop-repeats.sh cannot see the difference; this test can.
#
# clock_nanosleep(TIMER_ABSTIME) never returns early, so an update can only ever
# be late, never on the wrong side of the boundary. That is what makes the
# divisibility check deterministic rather than a timing gamble.
#
# The FIRST update is deliberately discarded: it is written immediately at
# startup, before any deadline exists, and is the one update that is not
# aligned.

. "${srcdir=.}/tests/init.sh"

updates_ () { grep -c '^CHANGEPROPERTY ' "$FAKEX_LOG" 2> /dev/null; }

have_updates_ () { test "$(updates_)" -ge "$1"; }

# check_alignment_ INTERVAL SAMPLES -- run the clock at INTERVAL until SAMPLES
# updates have been logged, then assert every update but the first is on a
# multiple of INTERVAL seconds.
check_alignment_ ()
{
	interval_=$1
	want_=$2
	status_=0

	stop_fakex_
	start_fakex_

	"$XRC" -i "$interval_" '%S' & pid_=$!

	if ! retry_ 30 have_updates_ "$want_"; then
		kill -KILL "$pid_" 2> /dev/null
		wait "$pid_" 2> /dev/null
		warn_ "$ME_: -i $interval_ produced $(updates_) updates in 30s, wanted $want_"
		cat "$FAKEX_LOG" >&2

		return 1
	fi

	kill -TERM "$pid_"
	wait "$pid_" 2> /dev/null

	sed -n 's/^CHANGEPROPERTY .*data=\(.*\)$/\1/p' "$FAKEX_LOG" |
		tail -n +2 > aligned.txt

	test -s aligned.txt || {
		warn_ "$ME_: -i $interval_ left no aligned samples to check"

		return 1
	}

	while read -r second_; do
		case $second_ in
			[0-9][0-9]) ;;
			*)
				warn_ "$ME_: -i $interval_: '%S' produced '$second_'"
				status_=1

				continue
				;;
		esac

		# Strip the leading zero first: $(( )) reads 08 and 09 as octal.
		value_=${second_#0}

		if test $(( value_ % interval_ )) -ne 0; then
			warn_ "$ME_: -i $interval_: update at :$second_" \
				"is not on a multiple of $interval_"
			warn_ "--- samples (first dropped) ---"
			cat aligned.txt >&2
			status_=1
		fi
	done < aligned.txt

	return $status_
}

check_alignment_ 2 4 || fail=1
check_alignment_ 3 3 || fail=1

Exit $fail
