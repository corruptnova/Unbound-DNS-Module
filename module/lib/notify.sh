#!/system/bin/sh
# Run by inotifyd for each file created in the module folder, as
# "notify.sh EVENTS DIR FILE". Wakes the supervisor at once when the manager
# disables or removes the module.
case "$3" in
    disable|remove) kill -USR1 "$UNBOUND_DAEMON_PID" 2>/dev/null ;;
esac
exit 0
