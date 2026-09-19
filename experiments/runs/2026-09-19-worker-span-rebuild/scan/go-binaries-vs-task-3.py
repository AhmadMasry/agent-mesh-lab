"""Follow-ups 19, task 3c, reading (e), second half: the module versions linked into THIS build's scanned Go binaries
beside task 3's, and the scan's counts by image beside task 3's. Rows are joined on (binary, module); the image column
is the ko.local tag, equal on both sides by construction, and is not compared. Reads four files; touches no cluster.

  python3 go-binaries-vs-task-3.py <task-3 go-binary-modules.csv> <this go-binary-modules.csv> <task-3 summary.csv> <this summary.csv>
"""
import csv
import sys


def mods(path):
    return {(r["binary"], r["module"]): (r["go"], r["version"]) for r in csv.DictReader(open(path, newline=""))}


a, b = mods(sys.argv[1]), mods(sys.argv[2])
print("(binary, module) rows: this rebuild %d, task 3 %d; on both sides %d; equal in Go version and module version: %d" % (
    len(b), len(a), len(set(a) & set(b)), sum(1 for k in set(a) & set(b) if a[k] == b[k])))
for k in sorted(set(a) | set(b)):
    if a.get(k) != b.get(k):
        print("  DIFFERS %s %s: %s | %s" % (k[0], k[1], b.get(k), a.get(k)))
for binary in sorted({k[0] for k in a} | {k[0] for k in b}):
    print("  %s: modules linked %d | %d; go %s | %s" % (
        binary, sum(1 for k in b if k[0] == binary), sum(1 for k in a if k[0] == binary),
        "/".join(sorted({v[0] for k, v in b.items() if k[0] == binary})), "/".join(sorted({v[0] for k, v in a.items() if k[0] == binary}))))


def summ(path):
    return {r["image_name"]: r for r in csv.DictReader(open(path, newline=""))}


sa, sb = summ(sys.argv[3]), summ(sys.argv[4])
cols = ("total", "critical", "high", "medium", "low", "negligible", "unknown")
print("scan findings by image, %s: this rebuild | task 3" % "/".join(cols))
for n in sorted(set(sa) | set(sb)):
    x, y = sb.get(n, {}), sa.get(n, {})
    hx, hy = "/".join(x.get(c, "?") for c in cols), "/".join(y.get(c, "?") for c in cols)
    print("  %-8s %s: %s | %s" % ("same" if hx == hy else "DIFFERS", n, hx, hy))
print("images with 0 findings: this rebuild %d of %d | task 3 %d of %d" % (
    sum(1 for r in sb.values() if r["total"] == "0"), len(sb), sum(1 for r in sa.values() if r["total"] == "0"), len(sa)))
