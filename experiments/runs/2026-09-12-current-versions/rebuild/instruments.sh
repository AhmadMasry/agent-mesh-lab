#!/usr/bin/env bash
# Follow-ups 10 phase 1: the instruments on the rebuilt cluster, in followups-9 rebuild #2's order.
# Committed scripts and run tools only; nothing is edited, restarted or deleted by hand.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-12-current-versions
D=experiments/runs/$RUNREL
SCR=<scratchpad>/5008ee34-eeb0-4d7c-a82b-45488493edbc/scratchpad
LOG=$SCR/phase1.txt
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s=$(date -u +%s)
	echo "## $label  started $(ts)" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	echo "## $label  finished $(ts)  exit=$rc  wall=$(( $(date -u +%s) - s ))s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
rejections() { # $1 = phase label, $2 = file
	{
		echo "# ztunnel policy rejections on the rebuilt cluster, $1. $(ts)"
		for p in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{" "}{end}'); do
			n=$(kubectl -n istio-system logs "${p%%:*}" 2>/dev/null | grep -c 'policy rejection')
			echo "   ${p%%:*} (${p##*:}): 'policy rejection' lines = $n"
			kubectl -n istio-system logs "${p%%:*}" 2>/dev/null | grep 'policy rejection' | sed 's/^/      /'
		done
	} > "$2" 2>&1
}
dangling() {
	python3 - "$D/trace" <<'PY'
import csv, glob, os, sys
d = sys.argv[1]
rows = []
for sub in sorted(glob.glob(os.path.join(d, "a3t-*"))):
    f = os.path.join(sub, "spans.csv")
    if not os.path.exists(f):
        rows.append((os.path.basename(sub), "no-spans.csv", "", "", "")); continue
    sp = list(csv.DictReader(open(f)))
    ids = {s["span_id"] for s in sp}
    roots = sum(1 for s in sp if not s["parent_span_id"])
    dang = sum(1 for s in sp if s["parent_span_id"] and s["parent_span_id"] not in ids)
    rows.append((os.path.basename(sub), len(sp), len({s["trace_id"] for s in sp}), roots, dang))
with open(os.path.join(d, "dangling.csv"), "w") as o:
    o.write("work_item,spans,trace_ids,roots,dangling_parents\n")
    for r in rows: o.write(",".join(map(str, r)) + "\n")
print(open(os.path.join(d, "dangling.csv")).read())
PY
}

echo "# Follow-ups 10 phase 1 (instruments), started $(ts). HEAD $(git rev-parse HEAD)" > "$LOG"
step "readback (pins, certificates, egress first stream)" "$SCR/readback.sh" "$D/rebuild"
step "ztunnel rejections before the instruments" rejections "before the clean check, the wire-version capture, the trace and the probe (the Gate 1 baselines had already run)" "$D/rebuild/ztunnel-rejections-before.txt"
step "clean check" env RUN_ITEM=$RUNREL/clean-check experiments/gate2-single-clean.sh
step "wire version" env RUN_ITEM=$RUNREL/wire-version experiments/gate1-wire-version.sh
step "trace per work item REPS=2" env REPS=2 RUN_ITEM=$RUNREL/trace experiments/gate3-trace-per-work-item.sh
step "dangling parents" dangling
step "plaintext probe (after)" env OUT=../$RUNREL/mtls "$D/probe.sh" after
step "probe cleanup" env OUT=../$RUNREL/mtls "$D/probe.sh" cleanup
step "ztunnel rejections after" rejections "after the clean check, the wire-version capture, the trace and the probe" "$D/rebuild/ztunnel-rejections-after.txt"
step "prometheus targets" bash -c "{ echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# experiments/runs/2026-09-12-mtls-enforced/promq.sh targets'; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh targets; } > $D/rebuild/prometheus-targets.txt 2>&1"
step "tcp connection security raw" bash -c "{ echo '# istio_tcp_connections_opened_total, every series, $(ts): experiments/runs/2026-09-12-mtls-enforced/promq.sh security'; experiments/runs/2026-09-12-mtls-enforced/promq.sh security; } > $D/rebuild/tcp-connection-security-raw.txt 2>&1"
step "make scan-images" make scan-images SCAN_OUT=$D/scan
echo "# phase 1 finished $(ts)" >> "$LOG"
echo "$(ts) phase1 done"
