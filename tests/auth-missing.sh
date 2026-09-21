#!/bin/sh
# A cookie that cannot be read is not an error.
#
# What it pins:
#   - every way of having no .Xauthority at all still connects and still sets
#     the property: XAUTHORITY naming a file that does not exist, XAUTHORITY
#     empty with no $HOME/.Xauthority behind it, XAUTHORITY empty with HOME
#     unset entirely, and XAUTHORITY naming a directory rather than a file,
#   - and that in every one of those cases the setup request offers NO cookie:
#     "SETUP authname=0 authdata=0". Offering a name with an empty cookie, or a
#     length taken from an uninitialised buffer, would be a different line.
#
# Both halves matter. load_cookie() returning false must neither abort the
# program (an X server without access control accepts an anonymous client) nor
# leave *cookie_length set, which would put a junk auth block on the wire.
#
# The whole SETUP log is compared at the end rather than grepped: a grep for one
# good line cannot notice a fifth, wrong one.

. "${srcdir=.}/tests/init.sh"

start_fakex_

# run_ TAG -- one update, which must reach the server.
run_ ()
{
	returns_ 0 "$XRC" -1 "$1" || fail=1
	fakex_grep_ "CHANGEPROPERTY .* data=$1\$" || fail=1
}

# 1. XAUTHORITY names a file that is not there (init.sh's default).
XAUTHORITY=/nonexistent/xrootclock-test
export XAUTHORITY
run_ 'AUTH_MISSING_FILE'

# 2. XAUTHORITY empty, so $HOME/.Xauthority is consulted -- and is not there.
mkdir empty-home || framework_failure_ 'cannot create empty-home'
XAUTHORITY=''
HOME=$PWD/empty-home
export XAUTHORITY HOME
run_ 'AUTH_MISSING_HOME'

# 3. XAUTHORITY empty and HOME unset: there is no path to try at all.
unset HOME
run_ 'AUTH_MISSING_NOHOME'

# 4. XAUTHORITY names a directory. Opening it may succeed; reading it does not.
mkdir not-a-file || framework_failure_ 'cannot create not-a-file'
XAUTHORITY=$PWD/not-a-file
export XAUTHORITY
run_ 'AUTH_MISSING_DIR'

cat > setup.exp <<'EOF'
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
SETUP authname=0 authdata=0
EOF

grep '^SETUP ' "$FAKEX_LOG" > setup.out
compare setup.exp setup.out || fail=1

Exit $fail
