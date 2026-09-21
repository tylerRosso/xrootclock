#!/bin/sh
# With no FORMAT argument, the built-in default is used.
#
# What it pins:
#   - the default expands to " %a %m%d%y %I%M ": a leading space, the
#     abbreviated weekday, a six-digit mm dd yy date and a four-digit 12-hour
#     clock, 16 bytes in all;
#   - the default still applies when options are present, so it is not tied to
#     an empty argv;
#   - the usage text advertises the same string the program actually uses.
#
# The expected value cannot be a literal: it changes every minute. It is taken
# from date(1) instead -- which is an INDEPENDENT implementation of the same
# strftime(3) format, not the program's own DEFAULT_FORMAT macro -- sampled on
# both sides of the run, so a minute boundary landing mid-test cannot make it
# flap. init.sh pins TZ=UTC0 and LC_ALL=C, so both sides agree on the answer.

. "${srcdir=.}/tests/init.sh"

# timeout(1): a build that stopped honouring -1 would otherwise hang the suite
# forever instead of failing it.

require_prog_ date timeout

start_fakex_

before=$(date +' %a %m%d%y %I%M ') || framework_failure_ 'date failed'
returns_ 0 timeout 10 "$XRC" -1 2> default.err || fail=1
after=$(date +' %a %m%d%y %I%M ') || framework_failure_ 'date failed'

test -s default.err &&
	{ warn_ 'the default format wrote to stderr'; cat default.err >&2; fail=1; }

# Shape first: it says what went wrong when the value does not match.
# NOTE: the pattern below ends with a SPACE before the $ anchor, and that space
# is load-bearing -- the default format is padded on both sides. Do not let an
# editor trim it.
stamp='[A-Z][a-z][a-z] [0-9][0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]'
fakex_grep_ "CHANGEPROPERTY .* units=17 data= $stamp \$" || fail=1

# Then the value itself, against one of the two samples.
if grep -q "data=$before\$" "$FAKEX_LOG" ||
	grep -q "data=$after\$" "$FAKEX_LOG"; then
	:
else
	warn_ "$ME_: default output is neither '$before' nor '$after'"
	cat "$FAKEX_LOG" >&2
	fail=1
fi

# The default is not reserved for a bare argv: options may precede it.
stop_fakex_
start_fakex_

before=$(date +' %a %m%d%y %I%M ') || framework_failure_ 'date failed'
returns_ 0 timeout 10 "$XRC" -i 3600 -1 2> opts.err || fail=1
after=$(date +' %a %m%d%y %I%M ') || framework_failure_ 'date failed'

test -s opts.err &&
	{ warn_ 'the default format wrote to stderr'; cat opts.err >&2; fail=1; }

if grep -q "data=$before\$" "$FAKEX_LOG" ||
	grep -q "data=$after\$" "$FAKEX_LOG"; then
	:
else
	warn_ "$ME_: with options, default output is neither '$before' nor '$after'"
	cat "$FAKEX_LOG" >&2
	fail=1
fi

# The help text must document the format the program really defaults to.
returns_ 0 timeout 10 "$XRC" -h > help.out 2>&1 || fail=1
grep -q "^FORMAT defaults to ' %a %m%d%y %I%M '\.\$" help.out || {
	warn_ 'the usage text does not advertise the real default format'
	cat help.out >&2
	fail=1
}

Exit $fail
