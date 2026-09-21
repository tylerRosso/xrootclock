#!/bin/sh
# SIGINT and SIGHUP end the run cleanly too, exactly like SIGTERM.
#
# `wait` reports 128+signal -- 130 for SIGINT, 129 for SIGHUP -- when the
# process DIED from the signal rather than catching it, so "exit 0" here is a
# real assertion and not a formality.
#
# SIGINT is the interesting one. POSIX has the shell set SIGINT to SIG_IGN in a
# background child, so this only works because the program installs its own
# handler unconditionally, overriding what it inherited. A program that merely
# left SIGINT alone would sit there ignoring it.

. "${srcdir=.}/tests/init.sh"

for sig in INT HUP; do
	stop_fakex_
	start_fakex_

	"$XRC" -i 600 "SIG$sig" & pid=$!

	if ! fakex_grep_ "CHANGEPROPERTY .* data=SIG$sig\$"; then
		kill -KILL "$pid" 2> /dev/null
		wait "$pid" 2> /dev/null
		warn_ "$ME_: SIG$sig: the first update never arrived"
		fail=1

		continue
	fi

	kill -"$sig" "$pid"

	if ! fakex_grep_ '^DISCONNECT$'; then
		kill -KILL "$pid" 2> /dev/null
		wait "$pid" 2> /dev/null
		warn_ "$ME_: the program did not exit after SIG$sig"
		fail=1

		continue
	fi

	wait "$pid"
	status=$?

	test "$status" -eq 0 ||
		{ warn_ "$ME_: expected exit 0 after SIG$sig, got $status"; fail=1; }
done

Exit $fail
