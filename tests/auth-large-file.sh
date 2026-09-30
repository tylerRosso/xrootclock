#!/bin/sh
# A cookie is found however far into .Xauthority it is stored.
#
# .Xauthority only grows: every display number a forwarded session is given
# and every name this host has had adds an entry, and nothing takes one out.
# The entry for the local display can then sit behind more of them than a
# fixed buffer holds. The file was once read into 64 KiB and the rest ignored,
# so a cookie past that point was never offered, and the server refused the
# connection with nothing to say why.
#
# Same hand-built fixture as auth-cookie.sh: big-endian uint16 family, then four
# length-prefixed fields (address, display number, method name, cookie).
#
# What it pins:
#   - the matching entry is found behind enough entries for another display
#     to put it past 64 KiB, and its cookie is the one offered: the server logs
#     only the cookie's length, so the good one is given a length the filler
#     lacks,
#   - entries with a field longer than any that could match -- a 300-byte
#     address, a 40-digit display number, a 50-byte method name, a 100-byte
#     cookie -- are stepped over, not tripped over: the good entry behind them
#     is still found,
#   - a file that ends inside such a field is survived like any other
#     truncation, with no cookie offered.
#
# Seen to fail against the 64 KiB buffer this replaces, which found nothing in
# the first file, and with read_auth_field() ending the walk at a field longer
# than its buffer instead of reading past it, which lost the second.

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

# long_ N -- N bytes of text.
long_ ()
{
	printf "%0$1d" 0
}

# use_ FILE TAG -- point XAUTHORITY at FILE and do one update.
use_ ()
{
	XAUTHORITY=$PWD/$1
	export XAUTHORITY

	returns_ 0 "$XRC" -1 "$2" || fail=1
	fakex_grep_ "CHANGEPROPERTY .* data=$2\$" || fail=1
}

# 1. One entry for a display this is not -- fakex picks from :90 to :159 --
#    doubled until there is more than 64 KiB of it, then the one that matters.
entry_ 256 "$host" 1000 'MIT-MAGIC-COOKIE-1' '0123456789abcdef' > filler

i=0
while test $i -lt 11; do
	cat filler filler > filler.next && mv filler.next filler ||
		framework_failure_ 'cannot build the filler'
	i=$((i + 1))
done

test "$(wc -c < filler)" -gt 65536 ||
	framework_failure_ 'the filler does not reach past 64 KiB'

{
	cat filler
	entry_ 256 "$host" "$number" 'MIT-MAGIC-COOKIE-1' 'COOKIE_PAST_64KIB_20'
} > deep.xauth

# 2. One oversize field per entry, each otherwise as good as it gets, then the
#    good entry. Its being the one offered also says the FamilyLocal entry with
#    the unmatchable address did not stand in its way.
{
	entry_ 256 "$(long_ 300)" "$number" 'MIT-MAGIC-COOKIE-1' '0123456789abcdef'
	entry_ 256 "$host" "$(long_ 40)" 'MIT-MAGIC-COOKIE-1' '0123456789abcdef'
	entry_ 256 "$host" "$number" "$(long_ 50)" '0123456789abcdef'
	entry_ 256 "$host" "$number" 'MIT-MAGIC-COOKIE-1' "$(long_ 100)"
	entry_ 256 "$host" "$number" 'MIT-MAGIC-COOKIE-1' 'AFTER_OVERSIZE_FIELDS'
} > oversize.xauth

# 3. The first of those entries cut off inside its 300-byte address.
entry_ 256 "$(long_ 300)" "$number" 'MIT-MAGIC-COOKIE-1' '0123456789abcdef' \
	> whole.xauth
dd if=whole.xauth of=cut.xauth bs=1 count=100 2> /dev/null ||
	framework_failure_ 'cannot cut the fixture'

use_ deep.xauth     'AUTH_DEEP'
use_ oversize.xauth 'AUTH_OVERSIZE'
use_ cut.xauth      'AUTH_CUT'

cat > setup.exp <<'EOF2'
SETUP authname=18 authdata=20
SETUP authname=18 authdata=21
SETUP authname=0 authdata=0
EOF2

grep '^SETUP ' "$FAKEX_LOG" > setup.out
compare setup.exp setup.out || fail=1

Exit $fail
