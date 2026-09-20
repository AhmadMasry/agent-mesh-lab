"""Follow-ups 19, task 4b: the standard proof's counts on this rebuild beside REBUILD-2's, file by file.

experiments/runs/2026-09-19-worker-span-rebuild/standard-counts-vs-task-3.py, changed in: this docstring; the word
naming the other side in the printed labels (REBUILD-2 for task 3); the other side's retry-knob file (REBUILD-2 took
its knobs once, retry-knobs/readings.txt, where task 3 had a second take); and the A2A-Version section, which prints
that it was not taken here when this directory has no wire-version/ (this task drops readings (a)-(d), and the
wire-version capture was reading (b)). Every count and every comparison rule is that program's.

Reads the two run directories' committed outputs of the SAME scripts and prints, for every count, this rebuild's
value, REBUILD-2's value and `same` or `DIFFERS`. Work-item ids carry a per-run nonce (the same nonces on both sides
here: checks.sh is the same file), so rows are paired by what the row is (receiver, repetition, SDK and capture
point) and the id itself is printed, not compared. Nothing else is masked, except in the last section, where cluster/facts.txt
is compared with its `== <stamp>` headers and durations masked and every differing line is printed whole.
REBUILD-2's counts are what this is compared WITH; they are not pass marks. Reads files; touches no cluster.

  python3 standard-counts-vs-rebuild-2.py <REBUILD-2 run dir> <this run dir>
"""
import csv
import os
import re
import sys

T3, D = sys.argv[1], sys.argv[2]
n = {"same": 0, "DIFFERS": 0}


def rows(base, rel):
    return list(csv.DictReader(open(os.path.join(base, rel), newline="")))


def show(what, here, there):
    v = "same" if here == there else "DIFFERS"
    n[v] += 1
    print("  %-8s %s: %s | %s" % (v, what, here, there))


def kind(work_item):  # a3t-<nonce>-r1-orchestrator -> r1-orchestrator ; g2c-<nonce>-worker -> worker
    return work_item.split("-", 2)[2]


print("# every row: verdict, what, this rebuild | REBUILD-2")
print("## clean check (clean-check/summary.csv)")
a, b = rows(D, "clean-check/summary.csv"), rows(T3, "clean-check/summary.csv")
for ra, rb in zip(a, b):
    cols = [c for c in ra if c not in ("work_item", "receiver")]
    show("%s [%s | %s] %s" % (ra["receiver"], ra["work_item"], rb["work_item"], "/".join(cols)), "/".join(ra[c] for c in cols), "/".join(rb[c] for c in cols))
show("rows", len(a), len(b))

print("## trace per work item (trace/summary.csv)")
a = {kind(r["work_item"]): r for r in rows(D, "trace/summary.csv")}
b = {kind(r["work_item"]): r for r in rows(T3, "trace/summary.csv")}
for k in sorted(set(a) | set(b)):
    ra, rb = a.get(k, {}), b.get(k, {})
    for c in ("trace_ids", "spans", "spans_by_service", "hops_without_span", "lab_work_item_on_all"):
        show("%s %s" % (k, c), ra.get(c), rb.get(c))

print("## dangling parents (trace/dangling.csv)")
a = {kind(r["work_item"]): r for r in rows(D, "trace/dangling.csv")}
b = {kind(r["work_item"]): r for r in rows(T3, "trace/dangling.csv")}
for k in sorted(set(a) | set(b)):
    ra, rb = a.get(k, {}), b.get(k, {})
    show("%s spans/trace_ids/roots/dangling_parents" % k, "/".join(ra.get(c, "?") for c in ("spans", "trace_ids", "roots", "dangling_parents")),
         "/".join(rb.get(c, "?") for c in ("spans", "trace_ids", "roots", "dangling_parents")))

print("## GenAI spans (trace/genai/summary.csv)")
a = {kind(r["work_item"]): r for r in rows(D, "trace/genai/summary.csv")}
b = {kind(r["work_item"]): r for r in rows(T3, "trace/genai/summary.csv")}
for k in sorted(set(a) | set(b)):
    ra, rb = a.get(k, {}), b.get(k, {})
    cols = ("chat_spans", "invoke_agent_spans", "spans_missing_required", "spans_missing_expected", "spans_with_agent_id")
    show("%s chat/invoke_agent/missing Required/missing expected/agent.id" % k, "/".join(ra.get(c, "?") for c in cols), "/".join(rb.get(c, "?") for c in cols))


def targets(base):
    up, line = [], ""
    for x in open(os.path.join(base, "prometheus-targets.txt")):
        f = x.split()
        if len(f) >= 3 and f[1] in ("up", "down", "unknown"):
            up.append("%s=%s" % (f[0], f[1]))
        if "targets up" in x:
            line = x.strip().lstrip("- ")
    return sorted(up), line


print("## Prometheus targets (prometheus-targets.txt)")
(ua, la), (ub, lb) = targets(D), targets(T3)
show("the script's own total", la, lb)
show("jobs and health, sorted", "|".join(ua), "|".join(ub))

print("## STRICT: every ztunnel series (strict/hops-security.csv)")
a, b = rows_a, rows_b = None, None
with open(os.path.join(D, "strict/hops-security.csv")) as f:
    a = list(csv.DictReader(l for l in f if not l.startswith("#")))
with open(os.path.join(T3, "strict/hops-security.csv")) as f:
    b = list(csv.DictReader(l for l in f if not l.startswith("#")))
show("legs (rows)", len(a), len(b))
for pol in sorted({r["connection_security_policy"] for r in a + b}):
    show("legs with connection_security_policy=%s" % pol, sum(1 for r in a if r["connection_security_policy"] == pol), sum(1 for r in b if r["connection_security_policy"] == pol))
key = lambda r: tuple(r[c] for c in r if c != "connections_opened")
ka, kb = {key(r): r["connections_opened"] for r in a}, {key(r): r["connections_opened"] for r in b}
show("legs present on both sides, by every column but the connection count", len(set(ka) & set(kb)), len(kb))
for k in sorted(set(ka) - set(kb)):
    print("    only here:   %s  connections_opened=%s" % (",".join(k), ka[k]))
for k in sorted(set(kb) - set(ka)):
    print("    only REBUILD-2: %s  connections_opened=%s" % (",".join(k), kb[k]))
common = sorted(set(ka) & set(kb))
show("of the common legs, connection counts equal on", sum(1 for k in common if ka[k] == kb[k]), len(common))
for k in common:
    if ka[k] != kb[k]:
        print("    count differs: %s  %s | %s" % (",".join(k[:6]), ka[k], kb[k]))

print("## STRICT: the named legs (strict/legs.csv)")
a = {r["leg"]: r for r in rows(D, "strict/legs.csv")}
b = {r["leg"]: r for r in rows(T3, "strict/legs.csv")}
for k in list(b) + [x for x in a if x not in b]:
    ra, rb = a.get(k, {}), b.get(k, {})
    cols = ("series", "connection_security_policy", "connections_opened", "source_principal")
    show(k, "/".join(ra.get(c, "?") for c in cols), "/".join(rb.get(c, "?") for c in cols))

print("## plaintext probe (strict/plaintext-probe.csv, plaintext-probe-ztunnel.txt, ztunnel-other-error-lines.txt)")
a, b = rows(D, "strict/plaintext-probe.csv"), rows(T3, "strict/plaintext-probe.csv")
for ra, rb in zip(a, b):
    show(ra["target"], "http=%s curl_exit=%s" % (ra["http_code"], ra["curl_exit"]), "http=%s curl_exit=%s" % (rb["http_code"], rb["curl_exit"]))


def count(base, rel, pat):
    return sum(1 for x in open(os.path.join(base, rel), errors="replace") if re.search(pat, x))


for what, rel, pat in (
        ("ztunnel lines saying policy rejection", "strict/plaintext-probe-ztunnel.txt", r"policy rejection"),
        ("of them naming istio-system/istio_converted_static_strict", "strict/plaintext-probe-ztunnel.txt", r"istio-system/istio_converted_static_strict"),
        ("of them attributed to src.workload=mtls-probe", "strict/plaintext-probe-ztunnel.txt", r'src\.workload="mtls-probe"'),
        ("other ztunnel error/denied/reject lines, all", "strict/ztunnel-other-error-lines.txt", r"."),
        ("  of them `no healthy upstream`", "strict/ztunnel-other-error-lines.txt", r"no healthy upstream"),
        ("  of them `policy rejection`", "strict/ztunnel-other-error-lines.txt", r"policy rejection")):
    show(what, count(D, rel, pat), count(T3, rel, pat))

print("## A2A-Version (wire-version/summary.csv)")
taken = os.path.exists(os.path.join(D, "wire-version/summary.csv"))
if not taken:
    print("  not taken here: reading (b) of REBUILD-2 is not part of this task's proof; nothing compared, nothing counted")
a = {(r["client_sdk"], r["captured_at"]): r for r in rows(D, "wire-version/summary.csv")} if taken else {}
b = {(r["client_sdk"], r["captured_at"]): r for r in rows(T3, "wire-version/summary.csv")} if taken else {}
for k in sorted(set(a) | set(b)):
    ra, rb = a.get(k, {}), b.get(k, {})
    cols = [c for c in (ra or rb) if c not in ("work_item", "client_sdk", "captured_at")]
    show("%s captured at %s: %s" % (k[0], k[1], "/".join(cols)), "/".join(ra.get(c, "?") for c in cols), "/".join(rb.get(c, "?") for c in cols))


def knobs(path):
    seq, per = [], {}
    for x in open(path):
        m = re.search(r"grep -c 'retry:' -> (\d+)", x)
        if m:
            seq.append(m.group(1))
        m = re.match(r"\s+(\S+/\S+) retry_stanzas=(\d+)", x)
        if m:
            per.setdefault(m.group(1), []).append(m.group(2))
    return seq, per


print("## retry knobs (retry-knobs/readings.txt | REBUILD-2's retry-knobs/readings.txt)")
(sa, pa), (sb, pb) = knobs(os.path.join(D, "retry-knobs/readings.txt")), knobs(os.path.join(T3, "retry-knobs/readings.txt"))
show("stanzas across every route after each make call", ">".join(sa), ">".join(sb))
for r in sorted(set(pa) | set(pb)):
    show("%s, stanza count at each read" % r, ">".join(pa.get(r, [])), ">".join(pb.get(r, [])))
show("stanzas on every route at the last read", "+".join(v[-1] for _, v in sorted(pa.items())), "+".join(v[-1] for _, v in sorted(pb.items())))


def masked(base):
    out = []
    for x in open(os.path.join(base, "cluster/facts.txt"), errors="replace"):
        x = re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "<stamp>", x.rstrip("\n"))
        x = re.sub(r"\b\d+h\d+m\d+s\b|\b\d+m\d+s\b|\b\d+[smhd]\b", "<duration>", x)
        out.append(x)
    return out


print("## cluster facts (cluster/facts.txt), stamps and durations masked, every differing line whole")
fa, fb = masked(D), masked(T3)
show("lines", len(fa), len(fb))
import difflib
diff = [l for l in difflib.unified_diff(fb, fa, "REBUILD-2", "this rebuild", lineterm="", n=0) if not l.startswith(("---", "+++", "@@"))]
print("  differing lines (- REBUILD-2, + this rebuild): %d" % len(diff))
for l in diff:
    print("    " + l)
print("# rows: same=%d DIFFERS=%d (the cluster-facts lines above are listed, not counted here)" % (n["same"], n["DIFFERS"]))
