#!/usr/bin/env bash
# C-5 counts, from this run directory alone (reads files only): one row per probe of p0/ (no policy) and p1/ (the
# policy in force), and totals per cell. Columns:
#   http, curl_exit        the caller's own record (client.jsonl)
#   arrivals_<source>      pre-dispatch ingress ledger lines with phase arrival, per receiver that wrote them
#   executes_<source>      execution ledger lines with event execute
#   invocations            the mock's invocation lines, every one (stale-closed included; none is filtered)
#   agw_lines, agw_status  agw-central's access lines carrying the probe's trace id (agw-central-access.txt), and
#                          their http.status values in log order; agw_refused counts any status 403
#   agw_routes             the routes of those lines, in log order (a line is written when its request ends, so a
#                          model leg's line precedes the agent leg that carried it)
# The trace id joins a probe to its proxy lines; the work-item id joins it to its ledgers. Nothing is joined on order.
set -euo pipefail
cd "$(dirname "$0")"
out=counts.csv
echo "phase,receiver,op,probe_header,work_item,http,curl_exit,arrivals_worker,arrivals_orchestrator,executes_worker,executes_orchestrator,invocations,agw_lines,agw_status,agw_refused,agw_routes" > "$out"
for w in p0/*/ p1/*/; do
	c="$w/client.jsonl"
	t=$(jq -r .trace_id "$c")
	cnt() { [ -s "$w/$1" ] && jq -s "$2" "$w/$1" || echo 0; }
	aw=$(cnt ingress.jsonl '[.[] | select(.phase=="arrival" and .source=="worker")] | length')
	ao=$(cnt ingress.jsonl '[.[] | select(.phase=="arrival" and .source=="orchestrator")] | length')
	ew=$(cnt execution.jsonl '[.[] | select(.event=="execute" and .source=="worker")] | length')
	eo=$(cnt execution.jsonl '[.[] | select(.event=="execute" and .source=="orchestrator")] | length')
	inv=$(cnt invocation.jsonl 'length')
	lines=$(grep -c "trace.id=$t" agw-central-access.txt || true)
	sts=$(grep "trace.id=$t" agw-central-access.txt | sed -n 's/.*http\.status=\([0-9]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')
	ref=$(grep "trace.id=$t" agw-central-access.txt | grep -c 'http\.status=403' || true)
	route=$(grep "trace.id=$t" agw-central-access.txt | sed -n 's/.*route=\([^ 	]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')
	jq -r --arg aw "$aw" --arg ao "$ao" --arg ew "$ew" --arg eo "$eo" --arg inv "$inv" --arg l "$lines" --arg s "$sts" --arg r "$ref" --arg rt "$route" \
		'[.phase,.receiver,.op,.probe_header,.logical_work_item_id,.http_status,.exit_code,$aw,$ao,$ew,$eo,$inv,$l,$s,$r,$rt] | @csv' "$c" >> "$out"
done
echo "# totals per cell: phase receiver op probe_header -> probes, http=200, arrivals at the receiver asked, agw lines refused 403"
python3 - "$out" <<'PY'
import csv, sys, collections
rows = list(csv.DictReader(open(sys.argv[1])))
cells = collections.OrderedDict()
for r in rows:
    k = (r["phase"], r["receiver"], r["op"], r["probe_header"])
    c = cells.setdefault(k, collections.Counter())
    c["probes"] += 1
    c["http200"] += r["http"] == "200"
    own = "arrivals_worker" if r["receiver"] == "go" else "arrivals_orchestrator"
    c["arrived"] += int(r[own]) >= 1
    c["refused403"] += int(r["agw_refused"])
    c["executes"] += int(r["executes_worker"]) + int(r["executes_orchestrator"])
    c["invocations"] += int(r["invocations"])
for k, c in cells.items():
    print(" ".join(k), "->", " ".join(f"{n}={c[n]}" for n in ("probes", "http200", "arrived", "refused403", "executes", "invocations")))
print("all probes:", len(rows), "http200:", sum(r["http"] == "200" for r in rows), "refused403 lines:", sum(int(r["agw_refused"]) for r in rows))
PY
