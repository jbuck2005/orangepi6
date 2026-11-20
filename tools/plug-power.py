#!/usr/bin/env python3
"""Read-only power report from a smart plug's power sensor in Home Assistant.

Reads the sensor's history from Home Assistant's REST API and prints min/mean/max watts and the
energy used over a time window. It never switches the plug.

Config: a JSON file given with --config, or $PLUG_POWER_CONFIG, or ~/.config/plug-power.json:
  {
    "url": "https://homeassistant.example:8123",
    "sensor": "sensor.my_plug_power",
    "token_file": "~/.config/plug-power.token"
  }
The token file holds a Home Assistant long-lived access token (chmod 600). If it is a KEY=value
env file, add "token_var": "KEY". Instead of "sensor", "entity": "switch.<name>_relay" derives
sensor.<name>_power. --sensor overrides both. The URL and token are never printed.

Examples:
  plug-power.py                                 # last 60 minutes
  plug-power.py --minutes 15                    # last 15 minutes
  plug-power.py --start 2026-11-20T10:35:00Z --end 2026-11-20T11:35:00Z
  plug-power.py --minutes 60 --csv > power.csv  # raw samples
"""
import argparse
import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request

UTC = dt.timezone.utc


def parse_time(s):
    t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=UTC)


def read_token(cfg):
    path = os.path.expanduser(cfg["token_file"])
    var = cfg.get("token_var")
    with open(path, encoding="utf-8") as f:
        if not var:
            return f.read().strip()
        for line in f:
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            key, sep, val = line.partition("=")
            if sep and key.strip() == var:
                return val.strip().strip("'\"")
    sys.exit(f"token variable {var} not found in token file")


def sensor_from_switch(entity):
    name = entity.split(".", 1)[1]
    if name.endswith("_relay"):
        name = name[: -len("_relay")]
    return f"sensor.{name}_power"


def fetch_history(url, token, sensor, start, end):
    q = urllib.parse.urlencode(
        {"filter_entity_id": sensor, "end_time": end.isoformat(), "minimal_response": "", "no_attributes": ""}
    )
    path = urllib.parse.quote(start.isoformat(), safe="")
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/history/period/{path}?{q}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    samples = []
    for row in data[0] if data else []:
        try:
            w = float(row["state"])
        except (KeyError, ValueError):
            w = None  # unavailable / unknown: a gap, not a reading
        t = parse_time(row.get("last_changed") or row["last_updated"])
        samples.append((max(t, start), w))
    return samples


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=os.environ.get("PLUG_POWER_CONFIG", "~/.config/plug-power.json"))
    ap.add_argument("--sensor", help="power sensor entity id (default: from the config)")
    ap.add_argument("--minutes", type=float, default=60, help="window length ending now or at --end (default 60)")
    ap.add_argument("--start", help="window start, ISO 8601 (Z or offset; no offset = UTC)")
    ap.add_argument("--end", help="window end, ISO 8601 (default now)")
    ap.add_argument("--csv", action="store_true", help="print raw samples as CSV instead of a summary")
    a = ap.parse_args()

    with open(os.path.expanduser(a.config), encoding="utf-8") as f:
        cfg = json.load(f)
    sensor = a.sensor or cfg.get("sensor") or (cfg.get("entity") and sensor_from_switch(cfg["entity"]))
    if not sensor:
        sys.exit("no power sensor: set \"sensor\" in the config or pass --sensor")
    end = parse_time(a.end) if a.end else dt.datetime.now(UTC)
    start = parse_time(a.start) if a.start else end - dt.timedelta(minutes=a.minutes)
    if start >= end:
        sys.exit("start must be before end")

    samples = fetch_history(cfg["url"], read_token(cfg), sensor, start, end)
    if a.csv:
        print("time_utc,watts")
        for t, w in samples:
            print(f"{t.astimezone(UTC).isoformat()},{'' if w is None else w}")
        return
    watts = [w for _, w in samples if w is not None]
    if not watts:
        sys.exit(f"no numeric readings for {sensor} in the window")

    # History stores changes only, so each reading holds until the next change (or the window end).
    # Gaps (sensor unavailable) count toward neither energy nor the mean.
    wh = span_h = 0.0
    for (t, w), nxt in zip(samples, samples[1:] + [(end, None)]):
        if w is not None:
            h = (nxt[0] - t).total_seconds() / 3600
            wh += w * h
            span_h += h
    print(f"sensor   {sensor}")
    print(f"window   {start.astimezone(UTC):%Y-%m-%d %H:%M:%S}Z .. {end.astimezone(UTC):%Y-%m-%d %H:%M:%S}Z")
    print(f"readings {len(watts)}  (covered {span_h * 60:.0f} min)")
    print(f"watts    min {min(watts):.1f}  mean {wh / span_h if span_h else watts[0]:.1f}  max {max(watts):.1f}")
    print(f"energy   {wh:.1f} Wh")


if __name__ == "__main__":
    main()
