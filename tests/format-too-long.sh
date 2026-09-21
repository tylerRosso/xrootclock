#!/bin/sh
# A format whose OUTPUT does not fit must be diagnosed as too long, not as an
# unsupported conversion.
#
# Regression: strftime returns 0 for two unrelated reasons -- a conversion it
# does not know, and a result that will not fit the buffer -- and xrootclock
# cannot tell them apart from the return value alone. Guessing from the length
# of the FORMAT is wrong, because it is the OUTPUT that overflows: '%F' sixty
# times is 120 bytes of format that expands to 600 bytes of dates.
# That case was reported as an unsupported GNU extension, sending the user
# hunting for a %^ that was never there. The fix is a retry into a bigger
# probe buffer.
#
# Asserting the exact distinction between the two messages IS the test.

. "${srcdir=.}/tests/init.sh"

start_fakex_

# 120 bytes of format expanding to 600 bytes of output.
#
# %F, not %A. Weekday names are not a fixed width -- "Friday" is six letters and
# "Wednesday" is nine -- so '%A' x80 is 480 bytes on a Monday, Friday or Sunday
# and fits, while it is 720 on a Wednesday and does not. This test used %A and
# was therefore green four days a week and red the other three. %F is always
# exactly ten bytes, YYYY-MM-DD, on every day and in every locale.
format=
i=0
while test $i -lt 60; do
	format="$format%F"
	i=$(( i + 1 ))
done

returns_ 1 "$XRC" -1 "$format" 2> long.err || fail=1

grep -q 'expands to more than 511 bytes' long.err ||
	{ warn_ 'no "expands to more than 511 bytes" message'; fail=1; }

# This is the bug: it must NOT be blamed on a GNU extension.
grep -q 'produced no output' long.err &&
	{ warn_ 'too-long format was misdiagnosed as unsupported'; fail=1; }

grep -q 'GNU extensions' long.err &&
	{ warn_ 'too-long format was blamed on the GNU extensions'; fail=1; }

# Nothing may reach the server -- a truncated clock is still a wrong clock.
fakex_not_grep_ '^CHANGEPROPERTY ' || fail=1

# The ceiling itself, pinned from both sides with a format that has no % in it
# at all, so only the output size can be at fault. 511 bytes is the largest
# string that fits alongside strftime's terminating NUL in a 512-byte buffer.
text=
i=0
while test $i -lt 511; do
	text="${text}x"
	i=$(( i + 1 ))
done

returns_ 0 "$XRC" -1 "$text" 2> fits.err || fail=1
grep -q '^xrootclock:' fits.err &&
	{ warn_ '511 bytes complained'; cat fits.err >&2; fail=1; }
fakex_grep_ "units=511 data=$text\$" || fail=1

returns_ 1 "$XRC" -1 "${text}x" 2> over.err || fail=1
grep -q 'expands to more than 511 bytes' over.err ||
	{ warn_ '512 bytes was not reported as too long'; fail=1; }
fakex_not_grep_ 'units=512 ' || fail=1

Exit $fail
