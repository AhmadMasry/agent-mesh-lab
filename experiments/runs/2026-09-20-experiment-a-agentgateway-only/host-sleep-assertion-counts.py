"""Follow-ups 19, task 3c: how many of pmset's Assertions lines in each counted window name the `caffeinate`
process, of which assertion type, and with which of pmset's action words. COUNTS ONLY: this program never prints
a line of the log, a pid, an owner, a device or a product name -- an Assertions line can carry those.

experiments/runs/2026-09-19-currency-rebuild/host-sleep-assertion-counts.py with ONE change, asked for by that
record's review: the action word was the word after the FIRST occurrence of "caffeinate" on a line, which on
another log could be any word; here it is the word after the PROCESS TOKEN `PID <n>(caffeinate)` and nothing else,
and it is printed only if it is one of pmset's own action words listed in ACTIONS; any other word is counted under
`other-word` and never printed, and a line that names caffeinate without carrying that process token is counted
under `no-process-token`. The rest of the method is that program's: a line is an Assertions line when pmset's
event-kind column, field $4, is "Assertions" (the column host-sleep.sh selects by); its stamp is compared with the
window in UTC, both ends inclusive; it names caffeinate when its text holds the substring "caffeinate"; its type is
PreventUserIdleSystemSleep when its text holds that substring. What an action word means is pmset's: `Created` is
the start of a holder, `ClientDied` its end (the process exited while holding), `Summary` a periodic listing. A
count of lines is not a measure of how long an assertion was held. Read-only: `pmset -g log` only reads.

  pmset -g log | python3 host-sleep-assertion-counts.py <windows.csv>
"""
import collections
import datetime as dt
import re
import sys

TYPE = "PreventUserIdleSystemSleep"
ACTIONS = ("Created", "Released", "ClientDied", "Summary", "TimedOut", "Suspended", "Resumed", "Updated", "NameChange")
TOKEN = re.compile(r"PID\s+\d+\(caffeinate\)\s+(\w+)")
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
    word = ""
    if caff:
        m = TOKEN.search(line)
        word = "no-process-token" if not m else (m.group(1) if m.group(1) in ACTIONS else "other-word")
    rows.append((t, caff, TYPE in line, word))
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
