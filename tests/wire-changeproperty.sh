#!/bin/sh
# The bytes on the wire must match the X11 protocol spec.
#
# Asserted against LITERAL numbers from the spec, never against xrootclock's own
# X_OPCODE_CHANGE_PROP / X_ATOM_WM_NAME macros -- comparing the program to its
# own constants would pass even if every one of them were wrong.
#
#   opcode   18  ChangeProperty
#   mode      0  Replace
#   property 39  XA_WM_NAME
#   type     31  XA_STRING
#   format    8  bits per item

. "${srcdir=.}/tests/init.sh"

start_fakex_

returns_ 0 "$XRC" -1 'HELLO' || fail=1

fakex_grep_ '^REQUEST opcode=18 ' || fail=1
prop='CHANGEPROPERTY mode=0 window=0x[0-9a-f]* property=39 type=31 format=8'
fakex_grep_ "$prop units=5 data=HELLO\$" || fail=1

# The setup request must have offered the cookie method; with XAUTHORITY
# pointing at a missing file there is no cookie, so both lengths are zero.
fakex_grep_ '^SETUP authname=0 authdata=0$' || fail=1

Exit $fail
