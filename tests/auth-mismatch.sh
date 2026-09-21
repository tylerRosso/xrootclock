#!/bin/sh
# An .Xauthority entry that is not ours must be ignored, not used.
#
# Same hand-built fixture as auth-cookie.sh: big-endian uint16 family, then four
# length-prefixed fields (address, display number, method name, cookie).
#
# What it pins:
#   - an entry for a DIFFERENT display number is skipped. This is the one that
#     matters in practice: every entry in a real .Xauthority has the right
#     method and the right family, and the display number is all that separates
#     them,
#   - a method other than MIT-MAGIC-COOKIE-1 is skipped, including one that only
#     shares its length,
#   - a family that is neither FamilyLocal (256) nor FamilyWild (65535) is
#     skipped,
#   - an empty cookie is skipped, rather than offered as a zero-length one,
#   - a truncated entry and outright garbage are survived: the parser walks
#     length prefixes it read from the file, so a short file must stop the walk
#     rather than run off the end of the buffer. returns_ 0 is the crash
#     check -- a SIGSEGV here is exit 139, not 1.
#
# In all of them the program must still connect and still set the property, with
# "SETUP authname=0 authdata=0" proving no cookie was offered.

. "${srcdir=.}/tests/init.sh"

start_fakex_

number=${DISPLAY#:}
host=$(uname -n) || framework_failure_ 'cannot read the hostname'

test -n "$host" || skip_ 'this machine has no hostname'
test "$number" != 77 ||
	framework_failure_ 'start_fakex_ picked the display this test uses' \
		'as the wrong one'

u16_ ()
{
	printf "$(printf '\\%03o\\%03o' $(( ( $1 / 256 ) % 256 )) $(( $1 % 256 )))"
}

field_ ()
{
	u16_ ${#1}
	printf '%s' "$1"
}

entry_ ()
{
	u16_ "$1"
	field_ "$2"
	field_ "$3"
	field_ "$4"
	field_ "$5"
}

use_ ()
{
	XAUTHORITY=$PWD/$1
	export XAUTHORITY

	returns_ 0 "$XRC" -1 "$2" || fail=1
	fakex_grep_ "CHANGEPROPERTY .* data=$2\$" || fail=1
}

# Wrong display number, everything else right.
entry_ 256 "$host" 77 'MIT-MAGIC-COOKIE-1' '0123456789abcdef' \
	> wrongnumber.xauth

# Wrong method. The second one is exactly 18 bytes, so only the bytes differ.
{
	entry_ 256 "$host" "$number" 'XDM-AUTHORIZATION-1' '0123456789abcdef'
	entry_ 65535 '' "$number" 'MIT-MAGIC-COOKIE-2' '0123456789abcdef'
} > wrongmethod.xauth

# Wrong family: 0 is FamilyInternet, which this program has no transport for.
entry_ 0 '1.2.3.4' "$number" 'MIT-MAGIC-COOKIE-1' '0123456789abcdef' \
	> wrongfamily.xauth

# A matching entry carrying no cookie at all.
entry_ 256 "$host" "$number" 'MIT-MAGIC-COOKIE-1' '' > emptycookie.xauth

# A good entry chopped in half, mid method name.
entry_ 256 "$host" "$number" 'MIT-MAGIC-COOKIE-1' '0123456789abcdef' \
	> good.xauth
dd if=good.xauth of=truncated.xauth bs=1 count=30 2> /dev/null ||
	framework_failure_ 'cannot truncate the fixture'

# One stray byte: not even a family fits.
printf 'x' > onebyte.xauth

# Not an .Xauthority file in any sense. The leading bytes parse as enormous
# field lengths, which must stop the walk rather than be believed.
printf 'this is not an Xauthority file at all\n' > garbage.xauth

use_ wrongnumber.xauth 'MISMATCH_NUMBER'
use_ wrongmethod.xauth 'MISMATCH_METHOD'
use_ wrongfamily.xauth 'MISMATCH_FAMILY'
use_ emptycookie.xauth 'MISMATCH_EMPTY'
use_ truncated.xauth   'MISMATCH_TRUNCATED'
use_ onebyte.xauth     'MISMATCH_ONEBYTE'
use_ garbage.xauth     'MISMATCH_GARBAGE'

cat > setup.exp <<'EOF'
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
EOF

grep '^SETUP ' "$FAKEX_LOG" > setup.out
compare setup.exp setup.out || fail=1

Exit $fail
