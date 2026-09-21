#!/bin/sh
# A format strftime(3) cannot render must be fatal, and must set NOTHING.
#
# Regression: musl's strftime returns 0 for a GNU extension such as %^a, and
# when it returns 0 it DISCARDS THE WHOLE OUTPUT -- not just the offending
# conversion. xrootclock used to write that empty buffer to WM_NAME, silently
# blanking the status bar, and still exited 0.
#
# The important half of this test is fakex_not_grep_: exiting 1 while still
# having sent the blank ChangeProperty would be just as wrong.

. "${srcdir=.}/tests/init.sh"

start_fakex_

returns_ 1 "$XRC" -1 '%^a' 2> unsupported.err || fail=1

grep -q "format '%\^a' produced no output" unsupported.err ||
	{ warn_ 'no "produced no output" message'; fail=1; }

# The message must name what musl is missing, or the user has no way to guess.
grep -q 'GNU extensions' unsupported.err ||
	{ warn_ 'message does not mention the GNU extensions'; fail=1; }

# It is not a size problem, and must not be reported as one.
grep -q 'expands to more than' unsupported.err &&
	{ warn_ 'unsupported format was diagnosed as too long'; fail=1; }

# The blank property must never reach the server: not the ChangeProperty
# request (opcode 18), and not a zero-length property.
fakex_not_grep_ '^REQUEST opcode=18 ' || fail=1
fakex_not_grep_ '^CHANGEPROPERTY '    || fail=1

# The other extensions musl really does reject must behave the same way.
# (%-, %_ and %0 are NOT in this list on purpose: musl silently ignores those
# flag characters and renders the conversion, so they are not fatal here.)
for specifier in '%^A' '%#a' '%#A' '%q'; do
	returns_ 1 "$XRC" -1 "$specifier" 2> ext.err || fail=1
	grep -q 'produced no output' ext.err ||
		{ warn_ "no diagnostic for $specifier"; fail=1; }
done

fakex_not_grep_ '^CHANGEPROPERTY ' || fail=1

Exit $fail
