"""D-2 counts, from the run directory alone. One row per window, binding, receiver and kind; per send:
  client   the load client's outcome: its end/unary line's http_status (rest), grpc_status and grpc_attempts and
           grpc_transparent_attempts (grpc), result state or error; the curl's http status (cst)
  proxy    the ingress's own line for the request (the card GET excluded): route, http.status, grpc.status, reason
  ledgers  at the receiver asked (worker for go, orchestrator for py): ingress arrivals of the operation and their
           binding; execution received and execute lines; invocations at the mock
No figure is computed from an access-line timestamp; nothing is joined on a stamp. Identity: each send's own
directory holds only the lines make ledgers collected for its work item.
    python3 counts.py > counts.txt   (also writes counts.csv)
"""
import csv, json, os, re, sys
from collections import Counter, defaultdict
D = os.path.dirname(os.path.abspath(__file__))
WINDOWS = ["clean", "p0", "l1-route", "l2-path", "l3-deny", "l3-require", "l4-app"]

def jl(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out

def fields(line):
    f = dict(re.findall(r'(\S+?)=("[^"]*"|\S+)', line))
    return {k: v.strip('"') for k, v in f.items()}

rows = defaultdict(list)
for win in WINDOWS:
    wd = os.path.join(D, win)
    if not os.path.isdir(wd):
        continue
    for name in sorted(os.listdir(wd)):
        sd = os.path.join(wd, name)
        m = re.match(rf"{re.escape(win)}-(jsonrpc|rest|grpc)-(go|py)-(sm|st|cst)-", name)
        if not m or not os.path.isdir(sd):
            continue
        binding, recv, kind = m.groups()
        src = "worker" if recv == "go" else "orchestrator"
        op = "SendMessage" if kind == "sm" else "SubscribeToTask"
        client = jl(os.path.join(sd, "client.jsonl"))
        c = client[-1] if client else {}
        if kind == "cst":
            cout = f"curl http={c.get('http_status')}"
        else:
            st = c.get("state") or c.get("last_state") or ""
            cout = f"http={c.get('http_status', '-')}" if binding != "grpc" else f"grpc={c.get('grpc_status')}"
            cout += f" {'state=' + st if st else 'error=' + (c.get('error') or '')[:60]}"
        attempts = (c.get("grpc_attempts"), c.get("grpc_transparent_attempts")) if binding == "grpc" else None
        proxy = []
        for l in open(os.path.join(sd, "ingress-access.txt")) if os.path.exists(os.path.join(sd, "ingress-access.txt")) else []:
            f = fields(l)
            if f.get("http.path", "").endswith("agent-card.json"):
                continue
            proxy.append(f"{f.get('route')} http={f.get('http.status')}" + (f" grpc={f['grpc.status']}" if "grpc.status" in f else "")
                         + (f" reason={f['reason']}" if "reason" in f else ""))
        ing = [l for l in jl(os.path.join(sd, "ingress.jsonl")) if l.get("source") == src and l.get("phase") == "arrival" and l.get("method") == op]
        ex = [l for l in jl(os.path.join(sd, "execution.jsonl")) if l.get("source") == src]
        received = sum(1 for l in ex if l.get("event") == "received" and l.get("method") == op)
        executes = sum(1 for l in ex if l.get("event") == "execute")
        inv = len(jl(os.path.join(sd, "invocation.jsonl")))
        resp = [l for l in jl(os.path.join(sd, "ingress.jsonl")) if l.get("source") == src and l.get("phase") == "response" and l.get("method") == op]
        rans = ""
        if resp:
            r = resp[0]
            rans = f"status={r.get('status')}" + (f" grpc_status={r['grpc_status']}" if "grpc_status" in r else "")
        bindings = sorted({l.get("binding") or "jsonrpc" for l in ing})
        rows[(win, binding, recv, kind)].append(dict(send=name, client=cout, attempts=attempts, proxy=" | ".join(proxy) or "(no line)",
            arrivals=len(ing), arrival_binding=",".join(bindings), received=received, executes=executes, invocations=inv, receiver_answer=rans))

w = csv.writer(open(os.path.join(D, "counts.csv"), "w"), lineterminator="\n")
w.writerow(["window", "binding", "receiver", "kind", "sends", "client_outcomes", "grpc_attempts_transparent", "proxy_lines",
            "arrivals", "arrival_binding", "received", "executes", "invocations", "receiver_answers"])
flagged = []
for key in sorted(rows, key=lambda k: (WINDOWS.index(k[0]), k[1], k[2], k[3])):
    rs = rows[key]
    cl = Counter(r["client"] for r in rs)
    px = Counter(r["proxy"] for r in rs)
    ra = Counter(r["receiver_answer"] for r in rs if r["receiver_answer"])
    at = Counter(f"{r['attempts'][0]}/{r['attempts'][1]}" for r in rs if r["attempts"])
    for r in rs:
        if r["attempts"] and (r["attempts"][1] or 0) > 0:
            flagged.append(r["send"])
    vals = [*key, len(rs), "; ".join(f"{n}x {k}" for k, n in cl.items()), "; ".join(f"{n}x {k}" for k, n in at.items()) or "-",
            "; ".join(f"{n}x {k}" for k, n in px.items()), sum(r["arrivals"] for r in rs),
            ",".join(sorted({r["arrival_binding"] for r in rs if r["arrival_binding"]})) or "-",
            sum(r["received"] for r in rs), sum(r["executes"] for r in rs), sum(r["invocations"] for r in rs),
            "; ".join(f"{n}x {k}" for k, n in ra.items()) or "-"]
    w.writerow(vals)
    print(" | ".join(str(v) for v in vals))
print(f"# gRPC sends with a transparent attempt (grpc_transparent_attempts > 0): {len(flagged)} {flagged}")
