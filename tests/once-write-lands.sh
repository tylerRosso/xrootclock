#!/bin/sh
# The one-shot write must actually reach the server.
#
# Regression: xrootclock used to write ChangeProperty and exit immediately. The
# server saw the disconnect with the request still unread and discarded it, so
# the property was never set -- while the program still exited 0. It landed 0
# times out of 10. x_sync() (GetInputFocus) is what fixed it.
#
# This is why the test asserts the SERVER SAW IT, not that the program exited 0.

. "${srcdir=.}/tests/init.sh"

start_fakex_

i=1
while test $i -le 10; do
	returns_ 0 "$XRC" -1 "TAG$i" || fail=1
	fakex_grep_ "CHANGEPROPERTY .* data=TAG$i\$" || fail=1
	i=$(( i + 1 ))
done

# The round trip that makes it reliable must actually be on the wire.
fakex_grep_ '^REQUEST opcode=43 ' || fail=1
fakex_grep_ '^GETINPUTFOCUS$'     || fail=1

Exit $fail
