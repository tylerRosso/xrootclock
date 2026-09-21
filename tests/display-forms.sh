#!/bin/sh
# The local DISPLAY spellings that must all reach the same server.
#
# What it pins:
#   - ":N", "unix:N", ":N.0" and "unix:N.0" all resolve to /tmp/.X11-unix/XN and
#     complete a real update against the fake server. The screen suffix is
#     parsed off and discarded; the "unix" host is accepted where any other host
#     is not,
#   - a screen number other than 0 is still only a suffix, not part of the
#     display number -- ":N.1" must land on XN, never on XN.1,
#   - each form is proved by the property actually arriving at the server, not
#     by an exit status, so a form that parsed but connected nowhere would fail.
#
# The display number is whatever start_fakex_ picked; the other spellings are
# derived from it, so nothing here is pinned to a hardcoded :0.

. "${srcdir=.}/tests/init.sh"

start_fakex_

number=${DISPLAY#:}

case $number in
	'' | *[!0-9]*) framework_failure_ "start_fakex_ left DISPLAY as '$DISPLAY'" ;;
esac

# form_ SPELLING TAG -- run against DISPLAY=SPELLING and require the write to
# arrive at the fake server.
form_ ()
{
	DISPLAY=$1
	export DISPLAY

	returns_ 0 "$XRC" -1 "$2" || fail=1
	fakex_grep_ "CHANGEPROPERTY .* data=$2\$" || fail=1
}

form_ ":$number"        'FORM_PLAIN'
form_ "unix:$number"    'FORM_UNIX'
form_ ":$number.0"      'FORM_SCREEN'
form_ "unix:$number.0"  'FORM_UNIX_SCREEN'
form_ ":$number.1"      'FORM_SCREEN_ONE'

# Five connections, five updates: no form may have quietly reused another's.
test "$(grep -c '^CHANGEPROPERTY ' "$FAKEX_LOG")" -eq 5 ||
	{ warn_ 'expected exactly 5 updates'; cat "$FAKEX_LOG" >&2; fail=1; }

Exit $fail
