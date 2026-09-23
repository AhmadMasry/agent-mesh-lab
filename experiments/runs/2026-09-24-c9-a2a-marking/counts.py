#!/usr/bin/env python3
"""Experiment C, step C-9: counts from a phase directory written by c9.sh, from the files alone.

    python3 counts.py <phase dir> [<phase dir> ...]

For each phase it reads, per work item: both proxies' access lines, the proxy SERVER spans of the exported trace
(every span carrying a `route` attribute), the pre-dispatch ingress ledger, the execution ledger and the client lines.
It writes beside each phase: requests.csv (one row per proxy access line), proxy-spans.csv (one row per proxy span),
arrivals.csv (one row per ingress-ledger arrival, the sender named from the proxy pod IPs the phase recorded) and
clients.csv (one row per client end line), each with LF line ends, and prints the counts. Nothing here reads an access-line timestamp for a
figure (agentgateway#3369): the lines are joined by work item, by endpoint and by trace id only.
"""
import csv
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict

A2A_KEYS = ["protocol", "a2a.method", "a2a.response.outcome", "a2a.response.error_code", "a2a.result.kind",
            "a2a.task.state", "a2a.context.id"]
KV = re.compile(r'(\S+?)=("(?:[^"\\]|\\.)*"|\S*)')


def parse_line(line):
    out = {}
    body = line.split("request ", 1)[1] if "request " in line else line
    for k, v in KV.findall(body):
        out[k] = v[1:-1] if v.startswith('"') else v
    return out


def jl(path):
    rows = []
    if os.path.exists(path):
        for ln in open(path):
            ln = ln.strip()
            if ln:
                try:
                    rows.append(json.loads(ln))
                except ValueError:
                    pass
    return rows


def otlp_spans(path):
    if not os.path.exists(path):
        return []
    t = json.load(open(path))
    res = t.get("result", t)
    out = []
    for rs in res.get("resourceSpans", []):
        svc = ""
        for a in rs.get("resource", {}).get("attributes", []):
            if a["key"] == "service.name":
                svc = list(a["value"].values())[0]
        for ss in rs.get("scopeSpans", []):
            for s in ss.get("spans", []):
                attrs = {}
                for a in s.get("attributes", []):
                    v = a.get("value", {})
                    attrs[a["key"]] = str(list(v.values())[0]) if v else ""
                out.append({"service": svc, "name": s.get("name"), "kind": s.get("kind"), "traceId": s.get("traceId"),
                            "spanId": s.get("spanId"), "attrs": attrs})
    return out


def phase_counts(pd):
    phase = os.path.basename(pd.rstrip("/"))
    ips = dict(r.split(",") for r in open(os.path.join(pd, "proxy-ips.csv")).read().split())
    ip2proxy = {v: k for k, v in ips.items()}
    pods = {}
    for ln in open(os.path.join(pd, "pods-before.txt")):
        name = ln.split()[0].split("/")[1]
        ip = re.search(r"ip=(\S+)", ln).group(1)
        for app in ("worker", "orchestrator", "mockllm"):
            if name.startswith(app + "-"):
                pods[ip] = app
    reqs, spans, arrivals, clients = [], [], [], []
    wis = sorted(glob.glob(os.path.join(pd, "go", "*")) + glob.glob(os.path.join(pd, "py", "*")))
    for wd in wis:
        lwi = os.path.basename(wd)
        recv, kind = lwi.split("-")[2], lwi.split("-")[3]
        for proxy, f in (("agentgateway-ingress", "ingress-access.txt"), ("agw-central", "agw-central-access.txt")):
            for ln in open(os.path.join(wd, f)) if os.path.exists(os.path.join(wd, f)) else []:
                kv = parse_line(ln)
                ep = kv.get("endpoint", "").rsplit(":", 1)[0]
                row = {"phase": phase, "lwi": lwi, "recv": recv, "kind": kind, "proxy": proxy, "route": kv.get("route"),
                       "endpoint_app": pods.get(ep, ep), "http.method": kv.get("http.method"),
                       "http.path": kv.get("http.path"), "http.host": kv.get("http.host"),
                       "http.status": kv.get("http.status"), "trace.id": kv.get("trace.id")}
                for k in A2A_KEYS:
                    row[k] = kv.get(k, "")
                row["other_a2a_keys"] = " ".join(sorted(k for k in kv if k.startswith("a2a.") and k not in A2A_KEYS))
                row["id_keys"] = " ".join(sorted(k for k in kv if re.search(r"message|task\.id|taskid|message\.id", k, re.I)))
                reqs.append(row)
        for s in otlp_spans(os.path.join(wd, "trace", "trace.json")):
            if "route" not in s["attrs"]:
                continue
            a = s["attrs"]
            row = {"phase": phase, "lwi": lwi, "recv": recv, "kind": kind, "service": s["service"], "name": s["name"],
                   "route": a.get("route"), "http.method": a.get("http.method"), "http.path": a.get("http.path"),
                   "http.status": a.get("http.status"), "trace.id": s["traceId"]}
            for k in A2A_KEYS:
                row[k] = a.get(k, "")
            row["other_a2a_keys"] = " ".join(sorted(k for k in a if k.startswith("a2a.") and k not in A2A_KEYS))
            row["id_keys"] = " ".join(sorted(k for k in a if re.search(r"message|task\.id|taskid|task_id", k, re.I)))
            row["n_attrs"] = len(a)
            spans.append(row)
        for r in jl(os.path.join(wd, "ingress.jsonl")):
            if r.get("phase") != "arrival":
                continue
            rip = r.get("remote", "").rsplit(":", 1)[0]
            arrivals.append({"phase": phase, "lwi": lwi, "recv": recv, "kind": kind, "at": r.get("source"),
                             "method": r.get("method"), "sender": ip2proxy.get(rip, pods.get(rip, rip)),
                             "a2a_version": r.get("a2a_version"), "taskId": r.get("taskId"), "messageId": r.get("messageId")})
        for f in ("client.jsonl", "client-sub.jsonl"):
            for r in jl(os.path.join(wd, f)):
                if r.get("line", "end") != "end":
                    continue
                clients.append({"phase": phase, "lwi": lwi, "recv": recv, "kind": kind,
                                "method": r.get("method", "SendMessage"), "state": r.get("state") or r.get("last_state"),
                                "result_kind": r.get("result_kind") or r.get("first_kind"),
                                "stream_end": r.get("stream_end", ""), "content_type": r.get("content_type", ""),
                                "wire_error_code": r.get("wire_error_code", ""),
                                "advertised_urls": " ".join(r.get("advertised_urls") or []),
                                "dialled_url": r.get("dialled_url", ""), "host": r.get("host", "")})
    for name, rows in (("requests.csv", reqs), ("proxy-spans.csv", spans), ("arrivals.csv", arrivals), ("clients.csv", clients)):
        with open(os.path.join(pd, name), "w", newline="") as fh:
            if rows:
                w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
                w.writeheader()
                w.writerows(rows)
    return phase, reqs, spans, arrivals, clients


def ledger_view(wd):
    """What the ledgers say of each request at each receiver, keyed (receiver, method): a list of dicts."""
    out = defaultdict(list)
    ex = jl(os.path.join(wd, "execution.jsonl"))
    for r in ex:
        if r.get("event") == "result":
            out[(r.get("source"), r.get("method"))].append(
                {"state": r.get("state", ""), "contextId": r.get("contextId", ""), "result_kind": r.get("result_kind", ""),
                 "error": r.get("error", ""), "stream_end": r.get("stream_end", "")})
    return out


def report(pds):
    for pd in pds:
        phase, reqs, spans, arrivals, clients = phase_counts(pd)
        print(f"==== phase {phase} ({pd})")
        a2a_routes = [r for r in reqs if r["route"] and r["route"].startswith("lab/")]
        print(f"access lines: {len(reqs)}; on the lab/* routes (A2A Services): {len(a2a_routes)}; model route: "
              f"{sum(1 for r in reqs if r['route'] == 'agentgateway-waypoint/model-via-agw')}")
        print("-- access lines on lab/* routes, by proxy, route, kind of request and what the proxy wrote:")
        c = Counter()
        for r in a2a_routes:
            c[(r["proxy"], r["route"], r["http.method"], r["http.path"], r["protocol"] or "<absent>",
               r["a2a.method"] or "<absent>", r["a2a.response.outcome"] or "<absent>",
               r["a2a.response.error_code"] or "<absent>", r["a2a.result.kind"] or "<absent>",
               r["a2a.task.state"] or "<absent>", "set" if r["a2a.context.id"] else "<absent>")] += 1
        for k, v in sorted(c.items()):
            print(f"  {v:3d}  {' | '.join(k)}")
        print("-- model route lines: protocol values", dict(Counter(r["protocol"] or "<absent>" for r in reqs if r["route"] == "agentgateway-waypoint/model-via-agw")),
              "a2a.method values", dict(Counter(r["a2a.method"] or "<absent>" for r in reqs if r["route"] == "agentgateway-waypoint/model-via-agw")))
        print("-- other a2a.* keys on any access line:", dict(Counter(r["other_a2a_keys"] for r in reqs if r["other_a2a_keys"])) or 0,
              "; keys naming a message or task id:", dict(Counter(r["id_keys"] for r in reqs if r["id_keys"])) or 0)
        print(f"-- proxy SERVER spans: {len(spans)}")
        c = Counter()
        for s in spans:
            c[(s["service"], s["route"], s["http.method"], s["protocol"] or "<absent>", s["a2a.method"] or "<absent>",
               s["a2a.response.outcome"] or "<absent>", s["a2a.response.error_code"] or "<absent>",
               s["a2a.result.kind"] or "<absent>", s["a2a.task.state"] or "<absent>",
               "set" if s["a2a.context.id"] else "<absent>")] += 1
        for k, v in sorted(c.items()):
            print(f"  {v:3d}  {' | '.join(str(x) for x in k)}")
        print("-- other a2a.* keys on any proxy span:", dict(Counter(s["other_a2a_keys"] for s in spans if s["other_a2a_keys"])) or 0,
              "; keys naming a message or task id:", dict(Counter(s["id_keys"] for s in spans if s["id_keys"])) or 0)
        print(f"-- ingress-ledger arrivals: {len(arrivals)}; by work item's receiver, kind, the agent it arrived at, method, sender:")
        for k, v in sorted(Counter((a["recv"], a["kind"], a["at"], a["method"], a["sender"]) for a in arrivals).items()):
            print(f"  {v:3d}  {' | '.join(k)}")
        print("   A2A-Version on arrivals:", dict(Counter(a["a2a_version"] for a in arrivals)))
        print(f"-- client end lines: {len(clients)}; by receiver, kind, method, advertised -> dialled, outcome:")
        for k, v in sorted(Counter((c_["recv"], c_["kind"], c_["method"], c_["advertised_urls"], c_["dialled_url"], c_["host"] or "-",
                                    str(c_["state"]), str(c_["stream_end"]), str(c_["wire_error_code"])) for c_ in clients).items()):
            print(f"  {v:3d}  {' | '.join(k)}")
        # agreement: per work item and receiver, the a2a.method multiset on POST lines delivered to that receiver
        # against the ingress ledger's arrival methods at that receiver; and the response attributes against the
        # execution ledger's result lines for the same receiver and method.
        print("-- agreement with the ledgers (access lines, then spans):")
        by_wi = defaultdict(list)
        for r in a2a_routes:
            by_wi[r["lwi"]].append(r)
        agree = Counter()
        for wd in sorted(glob.glob(os.path.join(pd, "go", "*")) + glob.glob(os.path.join(pd, "py", "*"))):
            lwi = os.path.basename(wd)
            arr = defaultdict(Counter)
            for a in arrivals:
                if a["lwi"] == lwi:
                    arr[a["at"]][a["method"]] += 1
            posts = defaultdict(Counter)
            for r in by_wi[lwi]:
                if r["http.method"] == "POST" and r["http.path"] == "/":
                    posts[r["endpoint_app"]][r["a2a.method"] or "<absent>"] += 1
            for app in set(arr) | set(posts):
                if all(k == "<absent>" for k in posts[app]):
                    agree["method: absent on every POST line to " + app] += 1
                elif posts[app] == arr[app]:
                    agree["method: a2a.method multiset == ingress-ledger arrivals at " + app] += 1
                else:
                    agree[f"method: DIFFERS at {app}: proxy {dict(posts[app])} ledger {dict(arr[app])}"] += 1
            lv = ledger_view(wd)
            for r in by_wi[lwi]:
                if r["http.method"] != "POST" or not r["a2a.method"]:
                    continue
                res = lv.get((r["endpoint_app"], r["a2a.method"]), [])
                if not r["a2a.response.outcome"]:
                    agree[f"response attrs absent: {r['proxy']} {r['a2a.method']} (ledger result lines {len(res)}, stream_end {sorted(set(x['stream_end'] for x in res))})"] += 1
                    continue
                if not res:
                    agree[f"response attrs present, no ledger result line: {r['proxy']} {r['a2a.method']}"] += 1
                    continue
                x = res[0]
                ok_state = (r["a2a.task.state"] or "") == (x["state"] or "")
                ok_ctx = (r["a2a.context.id"] or "") == (x["contextId"] or "")
                ok_kind = (r["a2a.result.kind"] or "") == (x["result_kind"] or "")
                ok_out = (r["a2a.response.outcome"] == "error") == bool(x["error"])
                agree[f"response attrs vs execution result: {r['proxy']} {r['a2a.method']} outcome={'agree' if ok_out else 'DIFFERS'} "
                      f"kind={'agree' if ok_kind else 'DIFFERS'} state={'agree' if ok_state else 'DIFFERS'} context={'agree' if ok_ctx else 'DIFFERS'}"] += 1
        for k, v in sorted(agree.items()):
            print(f"  {v:3d}  {k}")
        span_by_trace = defaultdict(list)
        for s in spans:
            span_by_trace[(s["lwi"], s["trace.id"], s["route"])].append(s)
        sa = Counter()
        for r in reqs:
            ss = span_by_trace.get((r["lwi"], r["trace.id"], r["route"]), [])
            if not ss:
                sa["access line with no proxy span of the same trace and route in the export"] += 1
                continue
            same = any(all((s[k] or "") == (r[k] or "") for k in A2A_KEYS) for s in ss)
            sa["access line and its span carry the same seven keys and values" if same else "access line and span DIFFER"] += 1
        for k, v in sorted(sa.items()):
            print(f"  {v:3d}  {k}")
        print()


if __name__ == "__main__":
    report(sys.argv[1:])
