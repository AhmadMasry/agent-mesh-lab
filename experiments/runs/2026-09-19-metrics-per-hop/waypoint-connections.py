#!/usr/bin/env python3
"""Follow-ups 15, review fix M4: one row per ztunnel "connection complete" line on stdin -- source and destination
workload, when it opened (close time minus duration), when it closed, duration, bytes and outcome. Read-only."""
import datetime, re, sys
for l in sys.stdin:
    f = l.split()
    t, lvl = f[0], f[1]
    src = re.search(r'src\.workload="([^"]+)"', l).group(1).rsplit("-", 2)[0]
    dst = re.search(r'dst\.workload="([^"]+)"', l).group(1).rsplit("-", 2)[0]
    dur = int(re.search(r'duration="(\d+)ms"', l).group(1))
    bs = re.search(r"bytes_sent=(\d+)", l).group(1)
    br = re.search(r"bytes_recv=(\d+)", l).group(1)
    err = re.search(r'error="([^"]*)"', l)
    close = datetime.datetime.strptime(t[:26], "%Y-%m-%dT%H:%M:%S.%f")
    opened = (close - datetime.timedelta(milliseconds=dur)).strftime("%H:%M:%S.%f")[:12]
    tail = f', error="{err.group(1)}"' if err else ""
    print(f"  {src} -> {dst}: opened {opened}Z closed {t[11:23]}Z duration {dur} ms, bytes_sent={bs} bytes_recv={br}, {lvl}{tail}")
