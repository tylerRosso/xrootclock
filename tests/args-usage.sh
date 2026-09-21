#!/bin/sh
# Usage, unknown options and surplus arguments.

. "${srcdir=.}/tests/init.sh"

returns_ 0 "$XRC" -h     > help.out 2>&1 || fail=1
returns_ 0 "$XRC" --help > help2.out 2>&1 || fail=1
compare help.out help2.out || fail=1

grep -q '^Usage: xrootclock ' help.out || { warn_ 'no usage line'; fail=1; }

# -h must not need a display at all.
grep -q 'DISPLAY' help.out && { warn_ '-h touched DISPLAY'; fail=1; }

returns_ 1 "$XRC" --nope 2> bad.err || fail=1
grep -q "unknown option '--nope'" bad.err ||
	{ warn_ 'no unknown-option message'; fail=1; }

returns_ 1 "$XRC" -1 one two 2> extra.err || fail=1
grep -q "unexpected argument 'two'" extra.err ||
	{ warn_ 'no surplus-argument message'; fail=1; }

Exit $fail
