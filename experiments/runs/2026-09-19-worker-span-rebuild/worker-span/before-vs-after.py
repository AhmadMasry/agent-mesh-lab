"""Follow-ups 19, task 3c, reading (a): task 3's reading (h) (the live BEFORE) beside this rebuild's (the live AFTER),
field for field.

Both inputs are the text that ONE reading tool printed, experiments/runs/2026-09-19-currency-rebuild/worker-span/
worker-span-reading.py, unedited, for the work item the same committed row sent on each cluster. This program reads
those two texts and prints every field of every span the tool printed, and every ledger line, with both values and
one of three verdicts:
  same      the two values are equal;
  per-run   the key's value belongs to one run by construction (span and trace ids, parents, durations, peer
            addresses and ports, the proxy's endpoint and source address, message and conversation ids, the work-item
            id, which carries the run's nonce, and a latency);
  DIFFERS   anything else.
Nothing is masked or dropped: a per-run value is printed with both sides like any other. Spans are paired by
section and start order, which is the order the tool prints them in.

  python3 before-vs-after.py <before.txt> <after.txt>
"""
import re
import sys

PER_RUN = {"duration_ms", "span_id", "parent", "lab.work_item", "attr:lab.work_item", "attr:client.address",
           "attr:network.peer.address", "attr:network.peer.port", "attr:endpoint", "attr:src.addr", "attr:span.id",
           "attr:trace.id", "attr:duration", "attr:gen_ai.conversation.id", "attr:lab.message_id"}


def parse(path):
    sections, cur, span, in_attrs, head = [], None, None, False, ""
    for raw in open(path):
        line = raw.rstrip("\n")
        if line.startswith("## the row's own attribution"):
            break  # the appended copy of attribution.txt is the row's file, compared by the entry from the row's own summary
        if line.startswith("# ") and not sections and cur is None:
            if "spans; by service" in line:
                head = line.split(": ", 1)[1]
            continue
        if line.startswith("## "):
            cur = {"title": line[3:], "spans": [], "lines": []}
            sections.append(cur)
            span, in_attrs = None, False
            continue
        if cur is None:
            continue
        if line.startswith("  service="):
            span = []
            cur["spans"].append(span)
            in_attrs = False
            m = re.match(r"  service=(\S*) scope=(.*)$", line)
            span.append(("service", m.group(1)))
            span.append(("scope", m.group(2)))
            continue
        if span is not None and line.startswith("    every attribute:"):
            in_attrs = True
            continue
        if span is not None and in_attrs and line.startswith("      "):
            k, _, v = line.strip().partition("=")
            span.append(("attr:" + k, v))
            continue
        if span is not None and line.startswith("    duration_ms="):
            for tok in line.split():
                k, _, v = tok.partition("=")
                span.append((k, v))
            continue
        if span is not None and line.startswith("    "):
            k, _, v = line.strip().partition("=")
            span.append((k, v))
            continue
        if line.strip():
            cur["lines"].append(line)
    return head, sections


(ha, sa), (hb, sb) = parse(sys.argv[1]), parse(sys.argv[2])
n = {"same": 0, "per-run": 0, "DIFFERS": 0}


def row(field, a, b, force=None):
    v = force or ("same" if a == b else ("per-run" if field in PER_RUN else "DIFFERS"))
    n[v] += 1
    print("    %-8s %-36s %s | %s" % (v, field, a, b))


print("# BEFORE: %s" % sys.argv[1])
print("# AFTER:  %s" % sys.argv[2])
print("# every row: verdict, field, BEFORE | AFTER")
print("## spans in the trace, by service")
row("span count and services", ha, hb)
for i in range(max(len(sa), len(sb))):
    A = sa[i] if i < len(sa) else {"title": "<no such section>", "spans": [], "lines": []}
    B = sb[i] if i < len(sb) else {"title": "<no such section>", "spans": [], "lines": []}
    print("## %s" % A["title"])
    if A["title"] != B["title"]:
        row("section title", A["title"], B["title"])
    for j in range(max(len(A["spans"]), len(B["spans"]))):
        pa = A["spans"][j] if j < len(A["spans"]) else []
        pb = B["spans"][j] if j < len(B["spans"]) else []
        da, db = dict(pa), dict(pb)
        print("  span %d of the section (start order): %s | %s" % (j + 1, da.get("name", "<none>"), db.get("name", "<none>")))
        keys = [k for k, _ in pa] + [k for k, _ in pb if k not in da]
        for k in keys:
            row(k, da.get(k, "<not printed>"), db.get(k, "<not printed>"))
    la, lb = A["lines"], B["lines"]
    for j in range(max(len(la), len(lb))):
        xa = la[j].strip() if j < len(la) else "<no such line>"
        xb = lb[j].strip() if j < len(lb) else "<no such line>"
        lat = re.compile(r"latency_ms=\S+")
        if xa != xb and lat.sub("latency_ms=", xa) == lat.sub("latency_ms=", xb):
            row("ledger line %d" % (j + 1), xa, xb, force="per-run")
        else:
            row("ledger line %d" % (j + 1), xa, xb, force="same" if xa == xb else "DIFFERS")
print("# rows: same=%d per-run=%d DIFFERS=%d" % (n["same"], n["per-run"], n["DIFFERS"]))
