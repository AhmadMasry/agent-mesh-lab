"""Follow-ups 19, task 4b: what the committed trace.json of every A.3 repetition says on four points the matrix's
summary.csv does not carry, counted per row over its repetitions. Reads files only; touches no cluster.

  1. PROXY ENTRY SPANS: every SERVER span (kind 2) of an agentgateway proxy (agw-central and agentgateway-ingress on
     the topology of 2026-09-19; agentgateway-waypoint, agentgateway-waypoint-orch, agw-egress and agentgateway-ingress
     in the 2026-09-12 record, so the tool reads both), i.e. the span that carries a route, as (method, route, http.status, reason, retry.attempt). This is the count the brief asks for: in the rows
     where a receiver (or the mock) closes a connection, how many entry spans read http.status 503 with reason
     UpstreamFailure.
  2. PROXY ATTEMPT SPANS: every CLIENT span (kind 3) of those two services, as (method, upstream, http.status,
     status code), so a retry made inside the proxy is visible attempt by attempt.
  3. MARKED SPANS: every span carrying `lab.injection`, as (service, span name, lab.injection, status code, status
     message, http.response.status_code): the mock marks its own injected close, and since follow-ups 19 task 3b the
     Go worker marks its own close-after-read.
  4. CHAT SPANS: every span whose name starts with "chat" (the GenAI client span of a model call), as (service,
     status code, error.type): openai 3.16.2's narrowed connection-error branch is on this path.

Each distinct tuple is printed with the number of repetitions it occurs in and how many times in all, per row. A
value that belongs to one run (ids, addresses, durations) is never part of a tuple.

  python3 proxy-entry-spans.py <run dir> [<run dir> ...]   (each argument a matrix row's directory, a3-*)
"""
import collections
import glob
import json
import os
import sys

# the agentgateway proxies of the topology of 2026-09-19, and those of 2026-09-12 (so the tool reads both records)
PROXIES = ("agw-central", "agentgateway-ingress", "agentgateway-waypoint", "agentgateway-waypoint-orch", "agw-egress")
KIND = {1: "internal", 2: "SERVER", 3: "CLIENT", 4: "producer", 5: "consumer"}


def val(v):
    return next(iter(v.values())) if isinstance(v, dict) and v else ""


def spans(path):
    d = json.load(open(path))
    for rs in d["result"]["resourceSpans"]:
        svc = next((val(a["value"]) for a in rs["resource"]["attributes"] if a["key"] == "service.name"), "")
        for ss in rs.get("scopeSpans", []):
            for s in ss.get("spans", []):
                a = {x["key"]: val(x["value"]) for x in s.get("attributes", [])}
                st = s.get("status") or {}
                yield svc, s, a, st


def row(d):
    reps = sorted(glob.glob(os.path.join(d, "a3m-*", "trace.json")))
    tallies = {k: (collections.Counter(), collections.Counter()) for k in ("entry", "attempt", "marked", "chat")}
    for t in reps:
        seen = {k: collections.Counter() for k in tallies}
        for svc, s, a, st in spans(t):
            method = s["name"].split(" ", 1)[0]
            code = {0: "Unset", 1: "Ok", 2: "Error"}.get(st.get("code", 0), str(st.get("code")))
            if svc in PROXIES and s.get("kind") == 2:
                seen["entry"][(svc, method, a.get("route", "-"), a.get("http.status", "-"), a.get("reason", "-"), a.get("retry.attempt", "-"))] += 1
            elif svc in PROXIES and s.get("kind") == 3:
                seen["attempt"][(svc, s["name"], a.get("http.status", "-"), code)] += 1
            if "lab.injection" in a:
                seen["marked"][(svc, s["name"], a["lab.injection"], code, st.get("message", ""), a.get("http.response.status_code", "-"))] += 1
            if s["name"].startswith("chat"):
                seen["chat"][(svc, code, a.get("error.type", "-"))] += 1
        for k, c in seen.items():
            for tup, n in c.items():
                tallies[k][0][tup] += 1  # repetitions carrying it
                tallies[k][1][tup] += n  # occurrences
    return len(reps), tallies


def main():
    for d in sys.argv[1:]:
        n, tallies = row(d)
        print("== %s: %d repetitions with a trace.json" % (os.path.basename(os.path.normpath(d)), n))
        heads = {"entry": "proxy ENTRY spans (service, method, route, http.status, reason, retry.attempt)",
                 "attempt": "proxy ATTEMPT spans (service, name, http.status, span status)",
                 "marked": "spans carrying lab.injection (service, name, lab.injection, span status, status message, http.response.status_code)",
                 "chat": "chat spans (service, span status, error.type)"}
        for k in ("entry", "attempt", "marked", "chat"):
            reps, occ = tallies[k]
            print("  %s:" % heads[k])
            if not occ:
                print("    (none)")
            for tup, m in sorted(occ.items()):
                print("    in %2d of %d reps, %3d in all: %s" % (reps[tup], n, m, " | ".join(tup)))
        e = tallies["entry"]
        routes = sorted({tup[2] for tup in e[1] if tup[3] == "503" and tup[4] == "UpstreamFailure"})
        if not routes:
            print("  entry spans reading 503 / UpstreamFailure: 0")
        for r in routes:
            tups = [tup for tup in e[1] if tup[2] == r and tup[3] == "503" and tup[4] == "UpstreamFailure"]
            print("  entry spans reading 503 / UpstreamFailure on route %s: %d in all, over %s" % (
                r, sum(e[1][t] for t in tups), " + ".join("%d of %d reps (retry.attempt=%s)" % (e[0][t], n, t[5]) for t in tups)))
        print()


if __name__ == "__main__":
    main()
