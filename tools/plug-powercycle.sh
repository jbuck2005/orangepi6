#!/bin/bash
# One power cycle of aiPi through Home Assistant (runs the off/wait/on HA script), or a Shelly (Gen2+) or
# Tasmota plug. Same config as plug-watch.ps1.
#   tools/plug-powercycle.sh [config.json]   (default ~/.config/aipi-plug.json; keep it out of the repo)
set -euo pipefail
CFG=${1:-$HOME/.config/aipi-plug.json}
j() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$CFG" "$1"; }
TYPE=$(j type); HOST=$(j host); USER_=$(j user); PASS=$(j password); OFF=$(j offSeconds); OFF=${OFF:-30}
AUTH=(); [ -n "$USER_" ] && AUTH=(--digest -u "$USER_:$PASS")
case "$TYPE" in
  homeassistant)
    URL=$(j url); TOKEN=$(j token); SCRIPT=$(j script)
    curl -fsS -m 15 -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d "{\"entity_id\": \"$SCRIPT\"}" "${URL%/}/api/services/script/turn_on" >/dev/null ;;
  shelly)  curl -fsS -m 10 "${AUTH[@]}" "http://$HOST/rpc/Switch.Set?id=0&on=false&toggle_after=$OFF" >/dev/null ;;
  tasmota) curl -fsS -m 10 -G "http://$HOST/cm" --data-urlencode "cmnd=Backlog Power Off; Delay $((OFF * 10)); Power On" \
             ${USER_:+--data-urlencode "user=$USER_" --data-urlencode "password=$PASS"} >/dev/null ;;
  *) echo "unknown plug type '$TYPE' in $CFG" >&2; exit 1 ;;
esac
echo "aiPi power cycle started ($TYPE)"
