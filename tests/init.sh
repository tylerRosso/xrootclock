# Test harness for xrootclock, sourced by every tests/*.sh.
#
# Modelled on gnulib's tests/init.sh, which is what GNU coreutils uses. The
# vocabulary is deliberately the same, so anything written about coreutils tests
# reads across.
#
# Exit status convention, understood by build.sh test:
#   0   pass
#   1   fail          the program is wrong
#   77  skip          this environment cannot run the test, and that is fine
#   99  framework     the test's own setup broke -- NOT a program failure
#
# The usual shape of a test:
#
#   . "${srcdir=.}/tests/init.sh"
#   start_fakex_
#   "$XRC" -1 'HELLO' || fail=1
#   fakex_grep_ 'data=HELLO' || fail=1
#   Exit $fail

# --------------------------------------------------------------- environment

# Deterministic output: C locale fixes weekday/month names, UTC fixes the clock.
LC_ALL=C
LANG=C
TZ=UTC0
export LC_ALL LANG TZ

# Never read the real display or the user's cookie by accident. A test that
# wants the live display sets these itself, deliberately.
DISPLAY=:9999
XAUTHORITY=/nonexistent/xrootclock-test
export DISPLAY XAUTHORITY

# Same idea for PREFIX, and it matters more: the default is ~/.local, which is a
# directory on the user's real PATH. A test that ran `./build.sh install` and
# forgot to set PREFIX would install into it for real. Point it at a path that
# does not exist so a forgotten PREFIX fails loudly instead of succeeding
# somewhere it should never touch. Tests that install set PREFIX per invocation.
PREFIX=/nonexistent/xrootclock-test-prefix
export PREFIX

: "${XRC_ROOT:=$(cd "${srcdir:-.}" && pwd)}"
: "${XRC:=$XRC_ROOT/bin/release/xrootclock}"
: "${FAKEX:=$XRC_ROOT/bin/test/fakex}"
export XRC_ROOT XRC FAKEX

fail=0

# ------------------------------------------------------------------ outcomes

warn_ () { printf '%s\n' "$*" >&2; }

fail_ ()              { warn_ "$ME_: failed test: $*";    Exit 1;  }
skip_ ()              { warn_ "$ME_: skipped test: $*";   Exit 77; }
framework_failure_ () { warn_ "$ME_: set-up failure: $*"; Exit 99; }
fatal_ ()             { warn_ "$ME_: hard error: $*";     Exit 99; }

ME_=$(basename "$0")

# ------------------------------------------------------------------- helpers

# returns_ N CMD...  -- assert an exact exit status.
#
# `CMD || fail=1` cannot tell failure from a segfault, and a test that accepts
# any non-zero status will happily pass on a crash. Always assert the number.
returns_ ()
{
	returns_expected_=$1
	shift
	"$@"
	returns_actual_=$?

	if test "$returns_actual_" -ne "$returns_expected_"; then
		warn_ "$ME_: expected exit $returns_expected_, got $returns_actual_: $*"

		return 1
	fi

	return 0
}

# compare EXPECTED ACTUAL -- diff two files, printing the difference on failure.
compare ()
{
	if diff -u "$1" "$2" > compare.tmp 2>&1; then
		rm -f compare.tmp

		return 0
	fi

	warn_ "$ME_: $1 and $2 differ:"
	cat compare.tmp >&2
	rm -f compare.tmp

	return 1
}

# retry_ SECONDS CMD... -- poll until CMD succeeds or the deadline passes.
#
# Never sleep a fixed amount and hope. Poll, so a fast machine is fast and a
# loaded one still passes.
retry_ ()
{
	retry_limit_=$(( ${1} * 50 ))
	shift
	retry_i_=0

	while test "$retry_i_" -lt "$retry_limit_"; do
		if "$@"; then
			return 0
		fi

		retry_i_=$(( retry_i_ + 1 ))
		sleep 0.02
	done

	return 1
}

require_prog_ ()
{
	for require_prog_p_ in "$@"; do
		command -v "$require_prog_p_" > /dev/null 2>&1 ||
			skip_ "required program not found: $require_prog_p_"
	done
}

require_built_ ()
{
	for require_built_f_ in "$@"; do
		test -x "$require_built_f_" ||
			framework_failure_ "not built: $require_built_f_"
	done
}

# ---------------------------------------------------------------- fake server

FAKEX_LOG=fakex.log
fakex_pid_=
fakex_display_=

# start_fakex_ [MODE] -- run a fake X server and point DISPLAY at it.
#
# Picks a free display number rather than a fixed one, so a stale socket or a
# concurrent run cannot make an unrelated test fail. fakex itself refuses to
# bind a socket somebody is already serving, which is what makes this safe --
# in particular it can never attach to the real :0.
start_fakex_ ()
{
	start_fakex_mode_=${1:-ok}
	start_fakex_n_=90

	while test "$start_fakex_n_" -lt 160; do
		: > "$FAKEX_LOG"

		"$FAKEX" "$start_fakex_n_" "$start_fakex_mode_" >> "$FAKEX_LOG" 2>&1 &
		fakex_pid_=$!

		if retry_ 5 grep -q '^LISTENING' "$FAKEX_LOG"; then
			fakex_display_=":$start_fakex_n_"
			DISPLAY=$fakex_display_
			export DISPLAY

			return 0
		fi

		kill "$fakex_pid_" 2> /dev/null
		wait "$fakex_pid_" 2> /dev/null
		fakex_pid_=

		start_fakex_n_=$(( start_fakex_n_ + 1 ))
	done

	framework_failure_ "could not start fakex on any display from :90 to :159"
}

stop_fakex_ ()
{
	test -n "$fakex_pid_" || return 0

	kill "$fakex_pid_" 2> /dev/null
	wait "$fakex_pid_" 2> /dev/null
	fakex_pid_=
}

# fakex_grep_ PATTERN -- assert the server logged something matching PATTERN.
# Waits for it, because the server writes the line after the client exits.
fakex_grep_ ()
{
	if retry_ 5 grep -q -- "$1" "$FAKEX_LOG"; then
		return 0
	fi

	warn_ "$ME_: fakex log has no match for: $1"
	warn_ "--- $FAKEX_LOG ---"
	cat "$FAKEX_LOG" >&2
	warn_ "------------------"

	return 1
}

# fakex_not_grep_ PATTERN -- assert the server never logged PATTERN.
fakex_not_grep_ ()
{
	if grep -q -- "$1" "$FAKEX_LOG" 2> /dev/null; then
		warn_ "$ME_: fakex log unexpectedly matched: $1"
		cat "$FAKEX_LOG" >&2

		return 1
	fi

	return 0
}

# ------------------------------------------------------- tmpdir and teardown

# Override in a test to clean up anything outside the temporary directory.
cleanup_ () { :; }

Exit ()
{
	set +e
	exit "$1"
}

remove_tmp_ ()
{
	remove_tmp_status_=$?

	stop_fakex_
	cleanup_

	if test -n "$test_dir_" && test "${KEEP:-no}" != yes; then
		cd / && rm -rf "$test_dir_"
	elif test -n "$test_dir_"; then
		warn_ "$ME_: keeping $test_dir_"
	fi

	exit $remove_tmp_status_
}

require_built_ "$XRC" "$FAKEX"

test_dir_=$(mktemp -d "${TMPDIR:-/tmp}/xrc-$ME_.XXXXXX") ||
	framework_failure_ "cannot create a temporary directory"

trap remove_tmp_ EXIT
trap 'Exit 143' HUP INT TERM

cd "$test_dir_" || framework_failure_ "cannot cd to $test_dir_"
