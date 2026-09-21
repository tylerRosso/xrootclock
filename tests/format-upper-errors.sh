#!/bin/sh
# -u and the two strftime results that are not text: nothing, and too much.
#
# upper_ascii() runs on the strftime result BEFORE the check that turns a
# zero-length result into a fatal error, so the flag sits directly on top of
# the two bugs format-unsupported and format-too-long were written for. This
# pins that adding -u did not disturb either:
#
#   - an unsupported conversion (%^a, the very thing -u exists to replace) is
#     still fatal with the "produced no output" diagnostic, and STILL WRITES
#     NOTHING. Exiting 1 while having already sent the blank ChangeProperty
#     would blank the user's bar just the same;
#   - a format whose output does not fit is still reported as too long, not as
#     an unsupported extension;
#   - an empty format is still the one legitimate way to get a zero-length
#     result: exit 0 and a real ChangeProperty carrying units=0.
#
# The empty-format case is the one that would break if the length check were
# ever rewritten to look at the upper-cased text instead of the length.

. "${srcdir=.}/tests/init.sh"

require_prog_ timeout

# ------------------------------------------- an unsupported conversion, with -u

start_fakex_

returns_ 1 timeout 10 "$XRC" -1 -u '%^a' 2> unsupported.err || fail=1

grep -q "format '%\^a' produced no output" unsupported.err || {
	warn_ 'no "produced no output" message under -u'
	cat unsupported.err >&2
	fail=1
}

grep -q 'GNU extensions' unsupported.err || {
	warn_ 'the message under -u does not mention the GNU extensions'
	cat unsupported.err >&2
	fail=1
}

grep -q 'expands to more than' unsupported.err &&
	{ warn_ 'an unsupported format was diagnosed as too long under -u'; fail=1; }

# The blank property must never reach the server: not the request (opcode 18),
# and not a zero-length property.
fakex_not_grep_ '^REQUEST opcode=18 ' || fail=1
fakex_not_grep_ '^CHANGEPROPERTY '    || fail=1

# The same for the long spelling and for the other extensions musl rejects.
for specifier in '%^A' '%#a' '%q'; do
	returns_ 1 timeout 10 "$XRC" -1 --upper "$specifier" 2> ext.err || fail=1
	grep -q 'produced no output' ext.err || {
		warn_ "no diagnostic for $specifier under --upper"
		cat ext.err >&2
		fail=1
	}
done

fakex_not_grep_ '^CHANGEPROPERTY ' || fail=1

# ------------------------------------------------ an oversized result, with -u

# 512 lower-case bytes, one over the ceiling, and no % in it at all, so only
# the output size can be at fault. -u must not change which of the two
# diagnostics is chosen, and must not let a truncated line through.
text=
i=0
while test $i -lt 512; do
	text="${text}x"
	i=$(( i + 1 ))
done

returns_ 1 timeout 10 "$XRC" -1 -u "$text" 2> over.err || fail=1

grep -q 'expands to more than 511 bytes' over.err || {
	warn_ '512 bytes under -u was not reported as too long'
	cat over.err >&2
	fail=1
}

grep -q 'produced no output' over.err &&
	{ warn_ 'a too-long format under -u was misdiagnosed as unsupported'; fail=1; }

fakex_not_grep_ '^CHANGEPROPERTY ' || fail=1

# One byte less fits, and arrives upper-cased in full: the ceiling is the same
# 511 bytes with the flag as without it.
fits=${text%x}

returns_ 0 timeout 10 "$XRC" -1 -u "$fits" 2> fits.err || fail=1
test -s fits.err &&
	{ warn_ '511 bytes under -u complained'; cat fits.err >&2; fail=1; }

fakex_grep_ '^CHANGEPROPERTY .* units=511 data=XXXXX' || fail=1
fakex_not_grep_ 'units=511 data=.*x' || fail=1

# ----------------------------------------------------- an empty format, with -u

stop_fakex_
start_fakex_

returns_ 0 timeout 10 "$XRC" -1 -u '' 2> empty.err || fail=1

grep -q '^xrootclock:' empty.err && {
	warn_ 'an empty format under -u produced a diagnostic'
	cat empty.err >&2
	fail=1
}

# Literal protocol numbers: ChangeProperty=18, Replace=0, WM_NAME=39,
# STRING=31, format=8, and a zero-length value.
fakex_grep_ '^REQUEST opcode=18 ' || fail=1
prop='CHANGEPROPERTY mode=0 window=0x[0-9a-f]* property=39 type=31 format=8'
fakex_grep_ "$prop units=0 data=\$" || fail=1

# It must be a real clear, not the property being left untouched, so the
# request has to be followed by the round trip that makes it land.
fakex_grep_ '^GETINPUTFOCUS$' || fail=1

returns_ 0 timeout 10 "$XRC" -1 --upper '' 2> empty2.err || fail=1
grep -q '^xrootclock:' empty2.err && {
	warn_ 'an empty format under --upper produced a diagnostic'
	cat empty2.err >&2
	fail=1
}

Exit $fail
