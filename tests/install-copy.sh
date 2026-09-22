#!/bin/sh
# `./build.sh install` puts a working COPY of the release binary in $PREFIX/bin.
#
# SAFETY -- DO NOT "SIMPLIFY" THIS AWAY: every build.sh invocation below passes
# PREFIX explicitly, pointing at a directory inside this test's own temporary
# directory. The default PREFIX is $HOME/.local, whose bin is the one personal
# directory on this machine's PATH: a test that let the default stand would
# overwrite -- and, in tests/install-uninstall.sh, delete -- the binary the
# user's status bar is really running. build_sh_ refuses any PREFIX that is not
# under this directory, so a later edit cannot quietly reintroduce that.
#
# Everything is built and installed from a private COPY of the project, never
# from $XRC_ROOT: install rebuilds, and the clean case below deletes bin/, which
# is where the binary and the fake server that every later test needs live.
#
# WHAT IT PINS:
#   - the installed file exists, is mode 755, is a regular file and RUNS. An
#     `exit 0` from install proves nothing on its own: an empty or
#     non-executable file would exit 0 just as happily, so --help is run from
#     the installed path and its output checked.
#   - it is a COPY, not a symlink. `test ! -L` says so directly, and the clean
#     case says why it matters: after `./build.sh clean` has wiped bin/, a
#     symlink would dangle and the user's status bar would be gone. That
#     ordering IS the design decision, so it is asserted in that order.
#   - the installed bytes are the release binary's, byte for byte (cmp).
#   - install is idempotent, including over a RUNNING copy of itself: writing to
#     a running static binary gets ETXTBSY, and GNU install is expected to work
#     around it by unlinking first. Verified rather than assumed -- the inode
#     must change, and the running process must survive and still exit 0.
#   - $PREFIX/bin is created when it does not exist, nested path and all.
#
# PREFIX is always absolute here. build.sh cds to its own directory before it
# does anything, so a relative PREFIX would land next to build.sh, not next to
# you.

. "${srcdir=.}/tests/init.sh"

# Captured once, immediately: init.sh has already cd'd into the per-test
# temporary directory, and every path below is built from this.
top_=$PWD
prog=$(basename "$XRC")

# build_sh_ PROJ PREFIX SUBCOMMAND -- run PROJ/build.sh with an explicit PREFIX.
#
# The single door every build.sh invocation in this file goes through, so the
# safety rule above is enforced in one place instead of trusted seven times.
build_sh_ ()
{
	build_sh_proj_=$1
	build_sh_prefix_=$2
	build_sh_cmd_=$3

	case "$build_sh_prefix_" in
		"$top_"/*) ;;
		*) framework_failure_ "refusing a PREFIX outside $top_: $build_sh_prefix_" ;;
	esac

	PREFIX="$build_sh_prefix_" "$build_sh_proj_/build.sh" "$build_sh_cmd_"
}

# show_ FILE... -- dump captured output after a failed assertion.
#
# returns_ writes its own "expected exit N, got M" to stderr, which every call
# below has redirected into a file. Without this a failing run prints a bare
# FAIL and nothing else.
show_ ()
{
	for show_f_ in "$@"; do
		warn_ "--- $show_f_ ---"
		cat "$show_f_" >&2
	done
}

# make_proj_ DIR -- a private copy of the project to build and install from.
#
# build.sh resolves its own directory through `readlink -f` and builds there, so
# build.sh, main.c and xwire.h are a complete project. If that ever stops being
# true this fails loudly at the first build rather than silently testing
# $XRC_ROOT.
make_proj_ ()
{
	mkdir -p "$1" || framework_failure_ "cannot create $1"

	cp "$XRC_ROOT/build.sh" "$XRC_ROOT/main.c" "$XRC_ROOT/xwire.h" "$1" ||
		framework_failure_ "cannot copy the project into $1"

	test -x "$1/build.sh" || framework_failure_ "$1/build.sh is not executable"
}

# The first field of `ls -i`. stat(1) is not POSIX; this is.
inode_ ()
{
	ls -i "$1" | sed -n 's/^ *\([0-9][0-9]*\) .*/\1/p'
}

proj="$top_/proj"
prefix="$top_/opt"
target="$prefix/bin/$prog"
built="$proj/bin/release/$prog"

make_proj_ "$proj"

# ------------------------------------------------------- it installs and runs

returns_ 0 build_sh_ "$proj" "$prefix" install \
	> install1.out 2> install1.err || {
	show_ install1.out install1.err
	fail=1
}

# Exactly this, and on stdout. A warning about $PATH belongs on stderr, and
# tests/install-uninstall.sh pins that separately.
got=$(tail -1 install1.out)

test "x$got" = "xinstalled $target" || {
	warn_ "$ME_: expected 'installed $target' last on stdout, got '$got'"
	cat install1.out >&2
	fail=1
}

test -f "$target" || fail_ "install did not create $target"

# -rwxr-xr-x. The leading '-' is the symlink check the design turns on, too.
mode=$(ls -l "$target" | cut -c1-10)

test "x$mode" = "x-rwxr-xr-x" || {
	warn_ "$ME_: expected mode -rwxr-xr-x, got $mode"
	fail=1
}

test ! -L "$target" || {
	warn_ "$ME_: $target is a symlink; install must copy"
	fail=1
}

# It has to be the release binary, byte for byte -- not the debug one, and not
# a truncated write.
cmp "$built" "$target" || {
	warn_ "$ME_: the installed bytes differ from bin/release"
	fail=1
}

# And it must actually run. --help needs no display, which is just as well:
# init.sh points DISPLAY at a dead one.
returns_ 0 "$target" --help > help1.out 2>&1 || {
	show_ help1.out
	fail=1
}

grep -q '^Usage: xrootclock ' help1.out || {
	warn_ "$ME_: the installed binary did not print its usage:"
	cat help1.out >&2
	fail=1
}

# -------------------------------------------------------------- twice is fine

returns_ 0 build_sh_ "$proj" "$prefix" install \
	> install2.out 2> install2.err || {
	show_ install2.out install2.err
	fail=1
}

test -f "$target" || fail_ "the second install left no regular file at $target"

mode=$(ls -l "$target" | cut -c1-10)

test "x$mode" = "x-rwxr-xr-x" || {
	warn_ "$ME_: after the second install the mode is $mode, not -rwxr-xr-x"
	fail=1
}

cmp "$built" "$target" || {
	warn_ "$ME_: after the second install the bytes differ from bin/release"
	fail=1
}

returns_ 0 "$target" --help > help2.out 2>&1 || {
	show_ help2.out
	fail=1
}

# One binary, not a directory that grew a second copy.
count=$(ls "$prefix/bin" | wc -l)

test "$count" -eq 1 || {
	warn_ "$ME_: expected one file in $prefix/bin, found $count:"
	ls -l "$prefix/bin" >&2
	fail=1
}

# ------------------------------------------- over a copy that is still running

start_fakex_

before=$(inode_ "$target")

"$target" -i 60 'INSTALLTAG' & running=$!

alive_ () { kill -0 "$running" 2> /dev/null; }

wrote_ () { grep -q '^CHANGEPROPERTY ' "$FAKEX_LOG" 2> /dev/null; }

# It must still be running when install opens the file, or this case tests
# nothing at all. Wait for its first update rather than sleeping and hoping.
#
# Not reaching that point is a FAILURE, not a set-up failure: a copy we have
# just installed and already run is supposed to start. A framework_failure_
# here would report 99 -- "my fixture is wrong" -- for an install that produced
# an unusable binary, and would skip the clean case below as well.
if retry_ 10 wrote_ && alive_; then
	returns_ 0 build_sh_ "$proj" "$prefix" install \
		> install3.out 2> install3.err || {
		show_ install3.out install3.err
		fail=1
	}

	after=$(inode_ "$target")

	# The proof that install unlinked rather than writing into a busy text file.
	# Overwriting in place would have failed with ETXTBSY, or corrupted the
	# process still running from it.
	test "x$before" != "x$after" || {
		warn_ "$ME_: the reinstall kept inode $before," \
			"writing into the running binary"
		fail=1
	}

	alive_ || {
		warn_ "$ME_: the running copy died across the reinstall"
		fail=1
	}

	kill -TERM "$running" 2> /dev/null
	wait "$running"
	status=$?

	test "$status" -eq 0 || {
		warn_ "$ME_: the running copy exited $status after the reinstall, not 0"
		fail=1
	}
else
	warn_ "$ME_: the installed binary did not stay running," \
		"so the reinstall over a running copy went unchecked:"
	cat "$FAKEX_LOG" >&2
	kill -KILL "$running" 2> /dev/null
	wait "$running" 2> /dev/null
	fail=1
fi

stop_fakex_

returns_ 0 "$target" --help > help3.out 2>&1 || {
	show_ help3.out
	fail=1
}

cmp "$built" "$target" || {
	warn_ "$ME_: after the reinstall the bytes differ from bin/release"
	fail=1
}

# ------------------------------------------------ and it survives a full clean

returns_ 0 build_sh_ "$proj" "$prefix" clean > clean.out 2>&1 || {
	show_ clean.out
	fail=1
}

test ! -e "$proj/bin" || {
	warn_ "$ME_: clean left $proj/bin behind, so this case proves nothing"
	fail=1
}

test ! -L "$target" || {
	warn_ "$ME_: $target is a symlink, and clean has just made it dangle"
	fail=1
}

test -f "$target" ||
	fail_ "clean took the installed binary with it: $target is gone"

returns_ 0 "$target" --help > help4.out 2>&1 || {
	show_ help4.out
	fail=1
}

grep -q '^Usage: xrootclock ' help4.out || {
	warn_ "$ME_: the installed binary stopped working once bin/ was cleaned:"
	cat help4.out >&2
	fail=1
}

# -------------------------------------------------- it creates a nested bindir

nested="$top_/a/b/c"

test ! -e "$top_/a" || framework_failure_ "$top_/a exists already"

returns_ 0 build_sh_ "$proj" "$nested" install > nested.out 2> nested.err || {
	show_ nested.out nested.err
	fail=1
}

got=$(tail -1 nested.out)

test "x$got" = "xinstalled $nested/bin/$prog" || {
	warn_ "$ME_: expected 'installed $nested/bin/$prog' last on stdout, got '$got'"
	cat nested.out >&2
	fail=1
}

returns_ 0 "$nested/bin/$prog" --help > help5.out 2>&1 || {
	show_ help5.out
	fail=1
}

Exit $fail
