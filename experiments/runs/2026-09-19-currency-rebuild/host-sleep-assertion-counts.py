"""Follow-ups 19, task 3, fix round 1: how many of pmset's Assertions lines in each counted window name the
`caffeinate` process, of which assertion type, and with which of pmset's action words. COUNTS ONLY: this
program never prints a line of the log, a pid, an owner, a device or a product name -- an Assertions line can
carry those. Method (the reviewer's, stated so that two counts can be compared): a line is an Assertions line
when pmset's event-kind column, field $4, is "Assertions" (the column host-sleep.sh selects by); its stamp is
compared with the window in UTC, both ends inclusive; it names caffeinate when its text holds the substring
"caffeinate"; its type is PreventUserIdleSystemSleep when its text holds that substring; its action word is the
word after the process token. What an action word means is pmset's: `Created` is the start of a holder,
`ClientDied` its end (the process exited while holding), `Summary` a periodic listing. A count of lines is not a
measure of how long an assertion was held. Read-only: `pmset -g log` only reads.

  pmset -g log | python3 host-sleep-assertion-counts.py <windows.csv>
"""
import collections
import datetime as dt
import re
import sys

TYPE = "PreventUserIdleSystemSleep"
rows = []
for line in sys.stdin:
    f = line.split()
    if len(f) < 4 or f[3] != "Assertions":
        continue
    try:
        t = dt.datetime.strptime(" ".join(f[:3]), "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        continue
    caff = "caffeinate" in line
    m = re.search(r"caffeinate\)?\s+(\w+)", line) if caff else None
    rows.append((t, caff, TYPE in line, m.group(1) if m else ""))
named, total_caff = 0, 0
for w in open(sys.argv[1]):
    w = w.strip()
    if not w or w.startswith("#"):
        continue
    label, a, b = w.split(",")
    ta = dt.datetime.strptime(a, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    tb = dt.datetime.strptime(b, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    inside = [r for r in rows if ta <= r[0] <= tb]
    caff = [r for r in inside if r[1]]
    acts = collections.Counter(r[3] for r in caff)
    others = ", ".join("%s=%d" % kv for kv in sorted(acts.items()) if kv[0] != "Created")
    print("   window %s: %s .. %s" % (label, a, b))
    print("     Assertions lines=%d  naming caffeinate=%d  of those with type %s=%d  by action word: Created=%d%s" % (
        len(inside), len(caff), TYPE, sum(1 for r in caff if r[2]), acts.get("Created", 0), (", " + others) if others else ""))
