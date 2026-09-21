#!/bin/sh
# An empty format is legitimate and must succeed, clearing the property.
#
# strftime returns 0 for an empty format too, which is the one case where 0 is
# not an error. The check that makes an unrenderable format fatal has to carve
# this out, or `xrootclock -1 ''` -- the obvious way to blank the bar, and what
# `xsetroot -name ''` does -- would start failing instead.
#
# Pinned on the wire: exit 0, and a real ChangeProperty carrying zero units.

. "${srcdir=.}/tests/init.sh"

start_fakex_

returns_ 0 "$XRC" -1 '' 2> empty.err || fail=1

grep -q '^xrootclock:' empty.err &&
	{ warn_ 'empty format produced a diagnostic'; cat empty.err >&2; fail=1; }

# Literal protocol numbers: ChangeProperty=18, Replace=0, WM_NAME=39,
# STRING=31, format=8, and a zero-length value.
fakex_grep_ '^REQUEST opcode=18 ' || fail=1
prop='CHANGEPROPERTY mode=0 window=0x[0-9a-f]* property=39 type=31 format=8'
fakex_grep_ "$prop units=0 data=\$" || fail=1

# It must be a real clear, not the property being left untouched, so the
# request has to be followed by the round trip that makes it land.
fakex_grep_ '^GETINPUTFOCUS$' || fail=1

Exit $fail
