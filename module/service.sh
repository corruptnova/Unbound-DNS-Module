#!/system/bin/sh
# Run by the root manager after boot; starts the supervisor in the background.
MODDIR="${0%/*}"
nohup sh "$MODDIR/ctl.sh" daemon >/dev/null 2>&1 &
