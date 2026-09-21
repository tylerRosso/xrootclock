#!/bin/sh
# A real .Xauthority file, byte by byte, must end up on the wire.
#
# The fixture is built here rather than with xauth(1) so the test owns the
# layout it is asserting against. .Xauthority is big-endian, unlike the protocol
# connection, and is a flat sequence of entries:
#
#   uint16 family
#   uint16 len + bytes   address
#   uint16 len + bytes   display number, as ASCII digits
#   uint16 len + bytes   method name
#   uint16 len + bytes   cookie
#
# family 256 is FamilyLocal and 65535 is FamilyWild (X11/Xauth.h).
#
# What it pins:
#   - a matching MIT-MAGIC-COOKIE-1 entry is found and offered: the method name
#     is 18 bytes and the cookie length is whatever the file says,
#   - FamilyWild is accepted when no FamilyLocal entry matches this host,
#   - a FamilyLocal entry naming this host beats a FamilyWild one that appears
#     EARLIER in the file. The two cookies are given different lengths on
#     purpose, because that is the only part of them the server logs,
#   - the auth block is padded to a multiple of four. The 18-byte method name
#     and the 14-byte cookie of case 2 are both unpadded lengths; if either were
#     sent without its padding the server would lose framing and the
#     ChangeProperty that follows would never be logged.
#
# Every length here is the literal from the spec -- 18 for MIT-MAGIC-COOKIE-1 --
# never xrootclock's AUTH_METHOD_LEN.

. "${srcdir=.}/tests/init.sh"

start_fakex_

number=${DISPLAY#:}
host=$(uname -n) || framework_failure_ 'cannot read the hostname'

test -n "$host" || skip_ 'this machine has no hostname'

# u16_ N -- one big-endian 16-bit integer.
u16_ ()
{
	printf "$(printf '\\%03o\\%03o' $(( ( $1 / 256 ) % 256 )) $(( $1 % 256 )))"
}

# field_ TEXT -- a 16-bit length followed by that many bytes.
field_ ()
{
	u16_ ${#1}
	printf '%s' "$1"
}

# entry_ FAMILY ADDRESS NUMBER METHOD COOKIE -- one whole .Xauthority record.
entry_ ()
{
	u16_ "$1"
	field_ "$2"
	field_ "$3"
	field_ "$4"
	field_ "$5"
}

# use_ FILE TAG -- point XAUTHORITY at FILE and do one update.
use_ ()
{
	XAUTHORITY=$PWD/$1
	export XAUTHORITY

	returns_ 0 "$XRC" -1 "$2" || fail=1
	fakex_grep_ "CHANGEPROPERTY .* data=$2\$" || fail=1
}

# 1. The ordinary case: FamilyLocal, this host, a 16-byte cookie.
entry_ 256 "$host" "$number" 'MIT-MAGIC-COOKIE-1' '0123456789abcdef' \
	> local.xauth

# 2. FamilyWild with an empty address, and a cookie whose length is not a
#    multiple of four.
entry_ 65535 '' "$number" 'MIT-MAGIC-COOKIE-1' 'WILDCOOKIE1234' > wild.xauth

# 3. Both, wildcard first, so the preferred entry is the one found second.
{
	entry_ 65535 '' "$number" 'MIT-MAGIC-COOKIE-1' 'SHORTER8'
	entry_ 256 "$host" "$number" 'MIT-MAGIC-COOKIE-1' 'PREFERRED_LOCAL1'
} > both.xauth

use_ local.xauth 'COOKIE_LOCAL'
use_ wild.xauth  'COOKIE_WILD'
use_ both.xauth  'COOKIE_PREFERRED'

cat > setup.exp <<'EOF'
SETUP authname=18 authdata=16
SETUP authname=18 authdata=14
SETUP authname=18 authdata=16
EOF

grep '^SETUP ' "$FAKEX_LOG" > setup.out
compare setup.exp setup.out || fail=1

Exit $fail
