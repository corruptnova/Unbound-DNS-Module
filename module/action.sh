#!/system/bin/sh
# The manager's "Action" button: turn the DNS redirect off (e.g. to sign in
# to hotel or airport Wi-Fi) and back on.
MODDIR="${0%/*}"
state="$(sh "$MODDIR/ctl.sh" redirect toggle)"
echo "$state"
case "$state" in
    *off) echo "Apps now use the network's DNS. Press Action again to switch Unbound back on." ;;
    *on)  echo "All DNS goes to Unbound again." ;;
esac
