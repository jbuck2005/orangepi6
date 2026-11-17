#!/bin/bash
# Prove the netconsole path to the log host using the RUNNING (Armbian) kernel's netconsole
# module and the same target string the test kernel will use. Changes nothing permanent:
# the module is unloaded again at the end.
#   sudo tools/netconsole-selftest.sh /home/<user>/sky1-build/netconsole.conf
set -euo pipefail
CONF=${1:?netconsole.conf}
[ "$(id -u)" -eq 0 ] || { echo "FAIL: run with sudo" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
for v in REMOTE_IP REMOTE_MAC LOCAL_IP LOCAL_MAC; do [ -n "${!v:-}" ] || { echo "FAIL: $v empty" >&2; exit 1; }; done
if lsmod | grep -q '^netconsole '; then echo "FAIL: netconsole already loaded" >&2; exit 1; fi
TAG="sky1-netconsole-selftest-$(date +%s)"
modprobe netconsole netconsole="+6665@$LOCAL_IP/$LOCAL_MAC,6666@$REMOTE_IP/$REMOTE_MAC"
trap 'rmmod netconsole 2>/dev/null || true' EXIT
sleep 2
dmesg | grep -q 'netconsole: network logging started' || { echo "FAIL: netconsole did not start:" >&2; dmesg | grep -i netcon | tail -5 >&2; exit 1; }
echo "<6>$TAG" > /dev/kmsg
sleep 1
echo "  ok: netconsole started and sent tag $TAG"
echo "  check the log host for that tag"
