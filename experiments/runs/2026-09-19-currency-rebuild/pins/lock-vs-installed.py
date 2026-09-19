"""Follow-ups 19, task 3, reading (a): the distributions installed in the running orchestrator container against uv.lock.

Every installed distribution must be a package of the lock at the lock's version; a lock package that is not
installed is listed with the reason the lock itself gives (a dev-group dependency, or the project). Reads two
files; touches no cluster.

  python3 lock-vs-installed.py <uv.lock> <orchestrator-installed.txt> <out.csv>
"""
import csv
import re
import sys
import tomllib

lock = tomllib.load(open(sys.argv[1], "rb"))
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
locked = {norm(p["name"]): p for p in lock["package"]}
installed = {}
for line in open(sys.argv[2]):
    line = line.strip()
    if "==" in line:
        n, v = line.split("==", 1)
        installed[norm(n)] = v
rows = []
for n in sorted(set(locked) | set(installed)):
    lv = locked.get(n, {}).get("version", "")
    iv = installed.get(n, "")
    src = locked.get(n, {}).get("source", {})
    if n in locked and n in installed:
        verdict = "equal" if lv == iv else "DIFFERS"
    elif n in installed:
        verdict = "installed, not in the lock"
    elif "editable" in src or "virtual" in src:
        verdict = "the project itself (lock source %s); installed under its own name or not as a distribution" % ("editable" if "editable" in src else "virtual")
    else:
        verdict = "in the lock, not installed in the image"
    rows.append([n, lv, iv, verdict])
with open(sys.argv[3], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["package", "uv_lock", "installed_in_running_container", "verdict"])
    w.writerows(rows)
import collections
c = collections.Counter(r[3].split(" (")[0] for r in rows)
print("lock packages %d, installed distributions %d; %s" % (len(locked), len(installed), "; ".join("%s: %d" % kv for kv in sorted(c.items()))))
for r in rows:
    if r[3] != "equal":
        print("   %s lock=%s installed=%s -> %s" % tuple(r))
