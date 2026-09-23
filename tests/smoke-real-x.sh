#!/bin/sh
# The one-shot write must land on the REAL X server, 10 times out of 10.
#
# WHAT IT PINS: that x_sync() (GetInputFocus, opcode 43) genuinely defeats the
# write/exit race against a real Xorg -- not just against tests/fakex.c.
#
# WHY IT EXISTS SEPARATELY FROM once-write-lands.sh: fakex is our own code, and
# it could be wrong in exactly the same way the program is wrong. It reads the
# socket until EOF and logs everything it got, so it would happily "prove" a
# write that a real server discards. Only Xorg decides what a disconnecting
# client's unread input is worth.
#
# WHAT BUG IT CAUGHT: xrootclock used to write ChangeProperty and exit at once.
# The server saw the disconnect with the request still unread and dropped it, so
# `-1` landed 0 times out of 10 against real Xorg -- while exiting 0 every time.
# That is why this test reads the property back with xprop and counts, and never
# treats an exit status of 0 as evidence of anything.
#
# SAFETY: this touches the user's live desktop, so it is opt-in
# (XRC_TEST_REAL_X) and it restores the root WM_NAME from a cleanup_ override,
# which runs on the failing and interrupted paths too.
#
# KNOWN RACE: whatever drives the user's status bar rewrites the root WM_NAME
# about once a minute, and can overwrite our tag between the write and the
# read-back. Each trial therefore gets up to 3 attempts. That absorbs the race
# without weakening the assertion: a write that never reaches the server does
# not become a write that does, however many times it is repeated -- with
# x_sync() removed all 30 attempts fail, which is what the mutation run shows.

. "${srcdir=.}/tests/init.sh"

test "${XRC_TEST_REAL_X:-0}" = 1 ||
	skip_ 'set XRC_TEST_REAL_X=1 to run against the live X display'

test -S /tmp/.X11-unix/X0 ||
	skip_ 'no live X server: /tmp/.X11-unix/X0 is not a socket'
require_prog_ xprop

# A leaked xrootclock from an earlier test rewrites the same property and would
# beat every attempt here, making a correct build look broken. AGENTS.md calls
# this out explicitly; refuse to run rather than report a bogus failure.
if pgrep -x xrootclock > /dev/null 2>&1; then
	skip_ 'another xrootclock is running and would fight for WM_NAME'
fi

# init.sh deliberately points these at a dead display and a missing cookie file.
# This is the one test that wants the real ones: both xrootclock and xprop fall
# back to $HOME/.Xauthority when XAUTHORITY is unset, so unsetting it is all the
# authorisation this needs.
DISPLAY=:0
export DISPLAY
unset XAUTHORITY

# The value comes back wrapped in double quotes -- WM_NAME(STRING) = "..." --
# which must be stripped before it can be written back.
root_name_ ()
{
	xprop -root WM_NAME 2> /dev/null |
		sed -n 's/^WM_NAME([A-Z_]*) = "\(.*\)"$/\1/p'
}

original=$(root_name_)
test -n "$original" ||
	framework_failure_ "cannot read the root WM_NAME on $DISPLAY"

warn_ "$ME_: saved root WM_NAME: $original"

# Restore from cleanup_, not from the end of the test, so the desktop is put
# back even when a check fails or the run is interrupted. Idempotent, because
# the body below calls it explicitly as well.
restored_=no

cleanup_ ()
{
	test "$restored_" = no || return 0
	restored_=yes

	"$XRC" -1 "$original" > /dev/null 2>&1 ||
		warn_ "$ME_: COULD NOT RESTORE the root WM_NAME; it was: $original"
}

# ------------------------------------------------------------------ the count

tag_prefix="xrootclock-smoke-$$"
landed=0
i=1

while test $i -le 10; do
	tag="$tag_prefix-$i"
	attempt=1

	while :; do
		# Asserted exactly, because a crash is not a pass -- but on its own it
		# proves nothing, which is the whole point of the read-back below.
		returns_ 0 "$XRC" -1 "$tag" || fail=1

		got=$(root_name_)

		if test "x$got" = "x$tag"; then
			landed=$(( landed + 1 ))
			break
		fi

		attempt=$(( attempt + 1 ))

		if test $attempt -gt 3; then
			warn_ "$ME_: trial $i: wrote '$tag', read back '$got'"
			break
		fi
	done

	i=$(( i + 1 ))
done

if test "$landed" -ne 10; then
	warn_ "$ME_: the one-shot write landed $landed times out of 10" \
		"on the real X server"
	fail=1
fi

# ---------------------------------------------------------------- put it back

cleanup_

# Not asserted equal to "$original": the status bar may legitimately have
# retaken the property by now. What must not be true is that our tag is still on
# display.
after=$(root_name_)

case "$after" in
	*"$tag_prefix"*)
		warn_ "$ME_: the test tag is still on the root window: $after"
		fail=1
		;;
esac

Exit $fail
