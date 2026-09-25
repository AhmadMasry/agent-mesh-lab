#!/usr/bin/env bash
# COPY for the currency pass of 2026-09-25 (the controller's ruling: a driver whose outputs land in its own dated
# run directory runs from a copy in this pass's run directory, only its output path changed). Original:
# experiments/runs/2026-09-21-c3-c4-ztunnel/counts.sh. One change: R, below, is this copy's directory.
# Derives counts.csv from the files in this run directory alone (no cluster read).
# One row per work item. Ledger counts are path-wide for the work item (every source).
#   send_arrivals                   ingress-ledger arrival lines for the SendMessage. The agent-card GET's own
#                                   arrival line carries an empty work item, so `make ledgers` does not collect it and
#                                   it is not counted here; the GET's delivery is read from the caller's status and the
#                                   worker's GET SERVER span (proxy-spans.txt) instead
#   received, executes, tasks       execution-ledger `received`, `execute`, distinct taskIds at SUBMITTED
#   invocations                     invocation-ledger lines (outcome != stale-closed)
#   get / post                      what the caller saw: HTTP status, or 000 with curl's exit code
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
R="experiments/runs/2026-09-25-currency-rebuild/c3c4"
n() { if [ -s "$1" ]; then jq -s "$2" "$1"; else echo 0; fi; }
echo "work_item,phase,via,get,post,send_arrivals,received,executes,tasks,invocations,remote_of_send"
for d in "$R"/c34-* "$R"/g2c-c3-worker "$R"/after/g2c-c34after-worker; do
	w=$(basename "$d")
	if [ -s "$d/client.jsonl" ] && jq -e -s '.[0].via' "$d/client.jsonl" >/dev/null 2>&1; then
		phase=$(jq -r -s '.[0].phase' "$d/client.jsonl"); via=$(jq -r -s '.[0].via' "$d/client.jsonl")
		get=$(jq -r -s '.[] | select(.op=="GetAgentCard") | "\(.http_status)/exit\(.exit_code)"' "$d/client.jsonl")
		post=$(jq -r -s '.[] | select(.op=="SendMessage") | "\(.http_status)/exit\(.exit_code)"' "$d/client.jsonl")
	else
		case "$w" in g2c-c3-*) phase=c3-l4 ;; *) phase=after-removal ;; esac
		via=service-loadgen; get="loadgen"; post=$(jq -r -s 'last | "\(.result_kind)/\(.state)"' "$d/client.jsonl")
	fi
	echo "${w},${phase},${via},${get},${post},$(n "$d/ingress.jsonl" '[.[]|select(.phase=="arrival" and .method=="SendMessage")]|length'),$(n "$d/execution.jsonl" '[.[]|select(.event=="received")]|length'),$(n "$d/execution.jsonl" '[.[]|select(.event=="execute")]|length'),$(n "$d/execution.jsonl" '[.[]|select(.event=="state" and .state=="TASK_STATE_SUBMITTED")|.taskId]|unique|length'),$(n "$d/invocation.jsonl" '[.[]|select(.outcome!="stale-closed")]|length'),$(if [ -s "$d/ingress.jsonl" ]; then jq -r -s '[.[]|select(.phase=="arrival" and .method=="SendMessage")|.remote]|join(" ")' "$d/ingress.jsonl"; else echo none; fi)"
done
