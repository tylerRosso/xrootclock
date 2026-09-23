#!/bin/sh
# What install and uninstall SAY, what uninstall removes, and what install
# refuses to do.
#
# SAFETY -- DO NOT "SIMPLIFY" THIS AWAY: every build.sh invocation below passes
# PREFIX explicitly, pointing at a directory inside this test's own temporary
# directory. The default PREFIX is $HOME/.local, whose bin is on the user's
# real PATH -- and this file runs `uninstall`, which deletes. Letting the
# default stand here would remove the binary the user's status bar is really
# running. build_sh_ refuses any PREFIX that is not under this directory, so a
# later edit cannot quietly reintroduce that.
#
# Everything is built and installed from a private COPY of the project, never
# from $XRC_ROOT: install rebuilds, and one case below needs a project that has
# never been built at all.
#
# WHAT IT PINS:
#   - the PATH warning. A prefix whose bin is not on PATH leaves the user
#     wondering why the shell cannot find the program. The warning goes to
#     STDERR -- a message on stdout would end up inside the output of anything
#     that captures an install -- and it does not turn a successful install
#     into a failure: exit 0.
#   - no warning at all when the target directory IS on PATH.
#   - uninstall removes the installed copy, says "removed", exits 0; a second
#     uninstall says "nothing installed at" and STILL exits 0. Removing
#     something that is already gone is not an error.
#   - uninstall never builds. It is the one subcommand that must work in a tree
#     that has never been compiled, and it must not resurrect bin/ on the way
#     out.
#   - an unwritable $PREFIX/bin is refused with exit 1, and the message names
#     su, the one privilege tool every system has; sudo or doas may be absent,
#     so a message that says "try sudo" can be a dead end. Nothing must be
#     installed in that case.

. "${srcdir=.}/tests/init.sh"

# Captured once, immediately: init.sh has already cd'd into the per-test
# temporary directory, and every path below is built from this.
top_=$PWD
prog=$(basename "$XRC")

# build_sh_ PROJ PREFIX SUBCOMMAND -- run PROJ/build.sh with an explicit PREFIX.
#
# The single door every build.sh invocation in this file goes through, so the
# safety rule above is enforced in one place instead of trusted nine times.
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
make_proj_ ()
{
	mkdir -p "$1" || framework_failure_ "cannot create $1"

	cp "$XRC_ROOT/build.sh" "$XRC_ROOT/main.c" "$XRC_ROOT/xwire.h" "$1" ||
		framework_failure_ "cannot copy the project into $1"

	test -x "$1/build.sh" || framework_failure_ "$1/build.sh is not executable"
}

# The two directories the refusal cases make read-only. Restored from cleanup_,
# which init.sh runs on the failing and interrupted paths as well -- a
# directory left at mode 500 would keep the temporary directory from being
# removed, and the test would leak it.
ro_bin_="$top_/ro/bin"
ro_parent_="$top_/ro2"

cleanup_ ()
{
	chmod 700 "$ro_bin_" "$ro_parent_" 2> /dev/null || :
}

proj="$top_/proj"

make_proj_ "$proj"

# --------------------------------------- the warning, when it is not on PATH

off="$top_/off"
off_target="$off/bin/$prog"

case ":$PATH:" in
	*":$off/bin:"*)
		framework_failure_ "$off/bin is unexpectedly already on PATH" ;;
esac

returns_ 0 build_sh_ "$proj" "$off" install > off.out 2> off.err || {
	show_ off.out off.err
	fail=1
}

grep -q "not on your PATH" off.err || {
	warn_ "$ME_: no PATH warning on stderr after installing into $off/bin:"
	cat off.err >&2
	fail=1
}

grep -q "not on your PATH" off.out && {
	warn_ "$ME_: the PATH warning went to stdout:"
	cat off.out >&2
	fail=1
}

grep -q -F "installed $off_target" off.out || {
	warn_ "$ME_: the warning replaced the 'installed' line instead of joining it:"
	cat off.out >&2
	fail=1
}

test -f "$off_target" || fail_ "warned but installed nothing at $off_target"

# ------------------------------------------- and silence, when it IS on PATH

on="$top_/on"

# Only for this one invocation, and restored right after. The string put on
# PATH is character for character the "$PREFIX/bin" build.sh computes.
saved_path_=$PATH
PATH="$on/bin:$PATH"
export PATH

returns_ 0 build_sh_ "$proj" "$on" install > on.out 2> on.err || {
	show_ on.out on.err
	fail=1
}

PATH=$saved_path_
export PATH

test -s on.err && {
	warn_ "$ME_: installing into a directory on PATH still wrote to stderr:"
	cat on.err >&2
	fail=1
}

grep -q -F "installed $on/bin/$prog" on.out || {
	warn_ "$ME_: no 'installed' line:"
	cat on.out >&2
	fail=1
}

# ------------------------------------------------------------------ uninstall

returns_ 0 build_sh_ "$proj" "$off" uninstall > rm1.out 2> rm1.err || {
	show_ rm1.out rm1.err
	fail=1
}

got=$(tail -1 rm1.out)

test "x$got" = "xremoved $off_target" || {
	warn_ "$ME_: expected 'removed $off_target' on stdout, got '$got'"
	cat rm1.out >&2
	fail=1
}

test ! -e "$off_target" || {
	warn_ "$ME_: uninstall said 'removed' but $off_target is still there"
	fail=1
}

# Twice is not an error: there is nothing left to remove, which is the state the
# caller asked for.
returns_ 0 build_sh_ "$proj" "$off" uninstall > rm2.out 2> rm2.err || {
	show_ rm2.out rm2.err
	fail=1
}

got=$(tail -1 rm2.out)

test "x$got" = "xnothing installed at $off_target" || {
	warn_ "$ME_: expected 'nothing installed at $off_target' on stdout, got '$got'"
	cat rm2.out >&2
	fail=1
}

# ------------------------------------------------------ uninstall never builds

# A project copy that has never been compiled. If uninstall builds anything at
# all it has to leave a trace here.
virgin="$top_/virgin"

make_proj_ "$virgin"

returns_ 0 build_sh_ "$virgin" "$off" uninstall > rm3.out 2> rm3.err || {
	show_ rm3.out rm3.err
	fail=1
}

test ! -e "$virgin/bin" || {
	warn_ "$ME_: uninstall built something: $virgin/bin exists"
	ls -lR "$virgin/bin" >&2
	fail=1
}

test ! -e "$virgin/compile_commands.json" || {
	warn_ "$ME_: uninstall wrote $virgin/compile_commands.json"
	fail=1
}

# And in a tree that HAS been built, uninstall must leave the build alone rather
# than quietly refreshing it. `find -newer` catches the rebuild that `cmp` could
# not: a rebuilt binary is byte for byte the same one.
built="$proj/bin/release/$prog"

if test -f "$built"; then
	touch marker || framework_failure_ 'cannot create the timestamp marker'

	returns_ 0 build_sh_ "$proj" "$on" uninstall > rm4.out 2> rm4.err || {
		show_ rm4.out rm4.err
		fail=1
	}

	newer=$(find "$built" -newer marker)

	test -z "$newer" || {
		warn_ "$ME_: uninstall rebuilt $built"
		fail=1
	}
else
	warn_ "$ME_: $built is missing," \
		"so nothing here can tell a rebuild from a no-op"
	fail=1
fi

# ------------------------------------------------ an unwritable $PREFIX/bin

mkdir -p "$ro_bin_" || framework_failure_ "cannot create $ro_bin_"
chmod 500 "$ro_bin_" || framework_failure_ "cannot chmod $ro_bin_"

returns_ 1 build_sh_ "$proj" "$top_/ro" install > ro.out 2> ro.err || {
	show_ ro.out ro.err
	fail=1
}

grep -q 'is not writable' ro.err || {
	warn_ "$ME_: no 'not writable' message for $ro_bin_:"
	cat ro.err >&2
	fail=1
}

# sudo and doas may be absent; su is the one way out every system has.
grep -q 'su -c' ro.err || {
	warn_ "$ME_: the refusal does not name su:"
	cat ro.err >&2
	fail=1
}

test ! -e "$ro_bin_/$prog" || {
	warn_ "$ME_: install refused and installed anyway: $ro_bin_/$prog"
	fail=1
}

grep -q 'installed' ro.out && {
	warn_ "$ME_: install reported success on stdout while refusing:"
	cat ro.out >&2
	fail=1
}

chmod 700 "$ro_bin_" || framework_failure_ "cannot chmod $ro_bin_ back"

# ------------------------------------- and a $PREFIX/bin that cannot be made

mkdir -p "$ro_parent_" || framework_failure_ "cannot create $ro_parent_"
chmod 500 "$ro_parent_" || framework_failure_ "cannot chmod $ro_parent_"

returns_ 1 build_sh_ "$proj" "$ro_parent_/sub" install > mk.out 2> mk.err || {
	show_ mk.out mk.err
	fail=1
}

grep -q -F "cannot create $ro_parent_/sub/bin" mk.err || {
	warn_ "$ME_: no 'cannot create' message for an unmakeable bindir:"
	cat mk.err >&2
	fail=1
}

test ! -e "$ro_parent_/sub" || {
	warn_ "$ME_: $ro_parent_/sub was created after all"
	fail=1
}

chmod 700 "$ro_parent_" || framework_failure_ "cannot chmod $ro_parent_ back"

# uninstall must remove OUR binary and nothing else. Without this, changing
# `rm -f "$target"` to `rm -rf "$bindir"` passes the whole suite -- verified.
pfx4=$PWD/keep
mkdir -p "$pfx4/bin" || framework_failure_ "cannot create $pfx4/bin"
build_sh_ "$proj" "$pfx4" install > /dev/null 2>&1 || fail=1
: > "$pfx4/bin/innocent-bystander"
build_sh_ "$proj" "$pfx4" uninstall > /dev/null 2>&1 || fail=1

test -e "$pfx4/bin/innocent-bystander" ||
	{ warn_ 'uninstall removed an unrelated file from the bin directory'; fail=1; }
test -d "$pfx4/bin" ||
	{ warn_ 'uninstall removed the bin directory itself'; fail=1; }
test ! -e "$pfx4/bin/xrootclock" ||
	{ warn_ 'uninstall left the binary behind'; fail=1; }

Exit $fail
