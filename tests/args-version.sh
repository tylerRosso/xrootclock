#!/bin/sh
# -v and --version print the version.
#
# Pins: both print the same single line, xrootclock-MAJOR.MINOR with an
# optional .PATCH, on stdout, exit 0 and need no display; nothing goes to
# stderr. The value itself is not pinned -- every release changes it -- only
# the form, which is what scripts and packagers parse.
#
# Seen to fail against the program before -v existed, and with the -v case
# removed, with --version not recognised, with the version printed on stderr,
# and with a space in place of the '-'.

. "${srcdir=.}/tests/init.sh"

# init.sh points DISPLAY at a display that does not exist, so exit 0 is also
# the proof that no connection was attempted.
returns_ 0 "$XRC" -v        > v.out  2> v.err  || fail=1
returns_ 0 "$XRC" --version > v2.out 2> v2.err || fail=1
compare v.out v2.out || fail=1

test -s v.err && { warn_ '-v wrote to stderr'; cat v.err >&2; fail=1; }
test -s v2.err && { warn_ '--version wrote to stderr'; cat v2.err >&2; fail=1; }

lines=$(wc -l < v.out | tr -d ' ')
test "$lines" -eq 1 ||
	{ warn_ "$ME_: expected one line, got $lines"; cat v.out >&2; fail=1; }

grep -Eq '^xrootclock-[0-9]+\.[0-9]+(\.[0-9]+)?$' v.out ||
	{ warn_ 'not xrootclock-VERSION'; cat v.out >&2; fail=1; }

Exit $fail
