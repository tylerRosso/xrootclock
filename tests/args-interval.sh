#!/bin/sh
# -i / --interval: which values are accepted and which are refused.
#
# What it pins:
#   - the accepted range is 1..86400 inclusive, for both spellings;
#   - everything outside it, and everything that is not a bare decimal integer,
#     is refused with exit 1 and the EXACT message text;
#   - a refused interval updates nothing -- the program dies before it ever
#     talks to the server;
#   - '-i' as the last argument is refused rather than read past the end of
#     argv.
#
# The exact message is compared, not grepped for, because a fake server is
# running: without that comparison a test asserting only "exit 1" would pass
# on a build that ACCEPTED the bad value and then failed for some unrelated
# reason. Conversely the fake server is what makes the exit status meaningful
# at all -- against the harness's dead DISPLAY every run exits 1 regardless.

. "${srcdir=.}/tests/init.sh"

# Every run is bounded. A build that stopped honouring -1 would otherwise hang
# the suite forever instead of failing it.
require_prog_ timeout

start_fakex_

cat > range.exp <<'EOF'
xrootclock: interval must be between 1 and 86400 seconds.
EOF

# Refused: out of range, not a number, trailing garbage, empty, and values that
# make strtol(3) itself report ERANGE.
for bad in 0 -1 -60 86401 100000 abc '' 5x ' 5 x' 1.5 1e3 0x10 \
	99999999999999999999 -99999999999999999999; do
	returns_ 1 timeout 10 "$XRC" -1 -i "$bad" 'INTERVAL-BAD' 2> range.err || fail=1
	compare range.exp range.err || fail=1

	returns_ 1 timeout 10 "$XRC" -1 --interval "$bad" 'INTERVAL-BAD' \
		2> range2.err || fail=1
	compare range.exp range2.err || fail=1
done

# None of the above may have reached the server.
fakex_grep_    '^LISTENING '   || fail=1
fakex_not_grep_ '^CHANGEPROPERTY' || fail=1
fakex_not_grep_ 'INTERVAL-BAD'    || fail=1

# A missing value is its own error, and must not be read out of bounds.
cat > novalue.exp <<'EOF'
xrootclock: '-i' needs a value.
EOF

cat > novalue2.exp <<'EOF'
xrootclock: '--interval' needs a value.
EOF

returns_ 1 timeout 10 "$XRC" -i 2> novalue.err || fail=1
compare novalue.exp novalue.err || fail=1

returns_ 1 timeout 10 "$XRC" -1 -i 2> novalue3.err || fail=1
compare novalue.exp novalue3.err || fail=1

returns_ 1 timeout 10 "$XRC" --interval 2> novalue2.err || fail=1
compare novalue2.exp novalue2.err || fail=1

# Accepted: both ends of the range and a value in the middle, both spellings.
# -1 keeps each run to a single update, so the interval is only parsed, never
# waited on.
returns_ 0 timeout 10 "$XRC" -1 -i 1            'INTERVAL-1'     2> ok.err ||
	fail=1
returns_ 0 timeout 10 "$XRC" -1 -i 86400        'INTERVAL-MAX'   2>> ok.err ||
	fail=1
returns_ 0 timeout 10 "$XRC" -1 --interval 60   'INTERVAL-MID'   2>> ok.err ||
	fail=1
returns_ 0 timeout 10 "$XRC" -1 --interval 00042 'INTERVAL-ZEROS' 2>> ok.err ||
	fail=1

test -s ok.err &&
	{ warn_ 'a valid interval wrote to stderr'; cat ok.err >&2; fail=1; }

fakex_grep_ 'CHANGEPROPERTY .* data=INTERVAL-1$'     || fail=1
fakex_grep_ 'CHANGEPROPERTY .* data=INTERVAL-MAX$'   || fail=1
fakex_grep_ 'CHANGEPROPERTY .* data=INTERVAL-MID$'   || fail=1
fakex_grep_ 'CHANGEPROPERTY .* data=INTERVAL-ZEROS$' || fail=1

Exit $fail
