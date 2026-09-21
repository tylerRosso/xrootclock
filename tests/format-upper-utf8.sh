#!/bin/sh
# -u must not corrupt UTF-8.
#
# This is the reason upper_ascii() exists instead of a toupper(3) loop:
# toupper works one byte at a time, so anything that shifts bytes outside
# 'a'..'z' mangles the continuation bytes of a multi-byte character and puts
# invalid UTF-8 on the bar. Every byte of a UTF-8 sequence is >= 0x80, so the
# correct implementation passes all of them through untouched.
#
# What it pins, for a format holding e-acute, a degree sign, an em dash and
# n-tilde:
#   - every non-ASCII byte is BYTE-IDENTICAL with and without -u;
#   - only the ASCII a-z bytes changed;
#   - the byte length does not move.
#
# fakex escapes anything outside 0x20..0x7e as \xNN, so the comparison is on
# exact bytes rather than on rendered glyphs. The expected text is built with
# printf and octal escapes rather than pasted in raw, so this file stays
# 7-bit ASCII and cannot be damaged by an editor or a transfer that
# re-encodes it -- and the byte count is verified below in case a printf
# somewhere does not do octal.
#
# Mutation this is meant to catch (and the only test that does): upper-casing
# by byte, e.g. `if ((unsigned char)text[i] >= 'a') text[i] -= 32;`, which
# turns the 0xc3 of e-acute into 0xa3, or `text[i] &= ~0x20`, which turns the
# 0xb0 of the degree sign into 0x90.

. "${srcdir=.}/tests/init.sh"

require_prog_ timeout

capture_data_ ()
{
	sed -n 's/^CHANGEPROPERTY .*format=8 //p' "$FAKEX_LOG" > "$1" ||
		framework_failure_ "cannot read $FAKEX_LOG"
}

#   caf<c3 a9> 20<c2 b0>C <e2 80 94> se<c3 b1>or z9!
#
# The degree sign and the n-tilde are chosen deliberately: their second bytes,
# 0xb0 and 0xb1, have bit 0x20 set, so a naive `&= ~0x20` corrupts them. The
# em dash covers a three-byte sequence.
text=$(printf 'caf\303\251 20\302\260C \342\200\224 se\303\261or z9!') ||
	framework_failure_ 'printf failed'

units=$(printf '%s' "$text" | wc -c | tr -d ' ')

test "$units" = 26 ||
	framework_failure_ "the octal escapes did not produce 26 bytes, got $units"

start_fakex_

returns_ 0 timeout 10 "$XRC" -1 "$text" 2> utf8.err || fail=1
returns_ 0 timeout 10 "$XRC" -1 -u "$text" 2>> utf8.err || fail=1

test -s utf8.err &&
	{ warn_ 'a UTF-8 format wrote to stderr'; cat utf8.err >&2; fail=1; }

# Both runs, in order. Everything is stated at once: the ASCII letters are
# upper-cased, every \xNN escape is unchanged, and units= is 26 on both lines.
cat > utf8.exp <<'EOF'
units=26 data=caf\xc3\xa9 20\xc2\xb0C \xe2\x80\x94 se\xc3\xb1or z9!
units=26 data=CAF\xc3\xa9 20\xc2\xb0C \xe2\x80\x94 SE\xc3\xb1OR Z9!
EOF

capture_data_ utf8.out
compare utf8.exp utf8.out || fail=1

# Said again, directly and independently of the expected text above: pull the
# non-ASCII bytes out of each line and require the two sets to be identical.
# If a single continuation byte moved, these files differ.
sed -n 1p utf8.out | grep -o '\\x[0-9a-f][0-9a-f]' > plain.hex
sed -n 2p utf8.out | grep -o '\\x[0-9a-f][0-9a-f]' > upper.hex

test -s plain.hex ||
	framework_failure_ 'no escaped bytes in the log -- the UTF-8 never arrived'

compare plain.hex upper.hex ||
	{ warn_ '-u changed a non-ASCII byte'; fail=1; }

# A format that is nothing but multi-byte characters: with -u there is no a-z
# in it at all, so the whole property must come back untouched.
stop_fakex_
start_fakex_

only=$(printf '\303\251\302\260\342\200\224\303\261') ||
	framework_failure_ 'printf failed'
onlyunits=$(printf '%s' "$only" | wc -c | tr -d ' ')

test "$onlyunits" = 9 ||
	framework_failure_ "expected 9 bytes of non-ASCII text, got $onlyunits"

returns_ 0 timeout 10 "$XRC" -1 "$only" 2> only.err || fail=1
returns_ 0 timeout 10 "$XRC" -1 -u "$only" 2>> only.err || fail=1

test -s only.err &&
	{ warn_ 'an all-UTF-8 format wrote to stderr'; cat only.err >&2; fail=1; }

cat > only.exp <<'EOF'
units=9 data=\xc3\xa9\xc2\xb0\xe2\x80\x94\xc3\xb1
units=9 data=\xc3\xa9\xc2\xb0\xe2\x80\x94\xc3\xb1
EOF

capture_data_ only.out
compare only.exp only.out || fail=1

Exit $fail
