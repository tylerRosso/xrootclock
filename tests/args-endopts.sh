#!/bin/sh
# "--", and the two arguments that look like options but are not.
#
# What it pins:
#   - without "--" a leading-dash FORMAT is refused as an unknown option, exit
#     1, and nothing is written;
#   - "--" ends option parsing, so that same FORMAT lands -- the whole point of
#     supporting it;
#   - "--" shields even a string that collides with a real option, so "-- -h"
#     writes "-h" instead of printing the usage;
#   - a lone "-" is a FORMAT, not an option, and not an error;
#   - "--" with nothing after it is not an error and leaves the default format
#     in place.
#
# The rejection is checked before the first successful write, so that "the
# server never saw it" can be asserted directly rather than inferred.

. "${srcdir=.}/tests/init.sh"

# Every run is bounded. A build that stopped honouring -1 would otherwise hang
# the suite forever instead of failing it.
require_prog_ timeout

start_fakex_

# Unescaped, a leading-dash format is an option, and an unknown one.
returns_ 1 timeout 10 "$XRC" -1 '-15C rising' 2> unknown.err || fail=1
grep -q "^xrootclock: unknown option '-15C rising'\.\$" unknown.err || {
	warn_ 'no unknown-option message for an unescaped leading-dash format'
	cat unknown.err >&2
	fail=1
}
fakex_not_grep_ '^CHANGEPROPERTY' || fail=1

# The motivating case: the same status line, escaped.
returns_ 0 timeout 10 "$XRC" -1 -- '-15C rising' 2> minus.err || fail=1
test -s minus.err && {
	warn_ 'writing a leading-dash format complained'
	cat minus.err >&2
	fail=1
}
fakex_grep_ 'CHANGEPROPERTY .* units=11 data=-15C rising$' || fail=1

# "--" must shield a string that is otherwise a real option: this sets the
# property, it does not print the usage.
returns_ 0 timeout 10 "$XRC" -1 -- '-h' > dashh.out 2> dashh.err || fail=1
test -s dashh.out && { warn_ '"-- -h" printed the usage'; fail=1; }
test -s dashh.err &&
	{ warn_ '"-- -h" wrote to stderr'; cat dashh.err >&2; fail=1; }
fakex_grep_ 'CHANGEPROPERTY .* units=2 data=-h$' || fail=1

# A lone "-" is not an option -- it is the format, and a one-byte one.
returns_ 0 timeout 10 "$XRC" -1 - 2> dash.err || fail=1
test -s dash.err &&
	{ warn_ 'a lone "-" was rejected'; cat dash.err >&2; fail=1; }
fakex_grep_ 'CHANGEPROPERTY .* units=1 data=-$' || fail=1

# "--" with nothing after it: no format given, so the default applies. Its
# exact text is pinned by args-format-default; here its length and shape are
# what prove the default was used rather than an empty string.
returns_ 0 timeout 10 "$XRC" -1 -- 2> bare.err || fail=1
test -s bare.err &&
	{ warn_ 'a trailing "--" was rejected'; cat bare.err >&2; fail=1; }
stamp='[A-Z][a-z][a-z] [0-9][0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]'
fakex_grep_ "CHANGEPROPERTY .* units=17 data= $stamp \$" || fail=1

# Options before "--" still count, and an argument after the format is still
# surplus.
returns_ 1 timeout 10 "$XRC" -1 -- '-a' '-b' 2> extra.err || fail=1
grep -q "^xrootclock: unexpected argument '-b'\.\$" extra.err ||
	{ warn_ 'no surplus-argument message after "--"'; cat extra.err >&2; fail=1; }

Exit $fail
