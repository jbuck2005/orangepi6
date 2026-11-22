#!/usr/bin/env python3
"""Receive netconsole UDP packets and append them, timestamped, to a log file.

Usage: netconsole-listener.py [port] [logfile]
Defaults: port 6666, ~/opi6-netconsole/netconsole.log
"""
import os
import socket
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 6666
path = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/opi6-netconsole/netconsole.log")
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))
with open(path, "ab", buffering=0) as f:
    f.write(b"=== listener started %s port %d\n" % (time.strftime("%F %T").encode(), port))
    while True:
        data, _ = s.recvfrom(65535)
        f.write(time.strftime("%T ").encode() + data + (b"" if data.endswith(b"\n") else b"\n"))
