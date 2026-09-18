#!/usr/bin/env bash
# Follow-ups 15, commit 3: the live exposition of every Prometheus scrape target, read through the Kubernetes API
# server's proxy (`kubectl get --raw .../proxy/metrics`), and parsed into one row per metric family: target, family,
# type, the label names its samples carry, and how many samples it had. Read-only.
#
# Which targets: the ones Prometheus itself reports as active (/api/v1/targets, through a port-forward this script
# opens and closes), mapped to a pod by the target's discovered labels, or to a Service for a static target. The
# raw expositions go to $OUT/raw/, which .gitignore keeps out of the repository (experiments/runs/**/raw/); the
# parsed families are what is committed.
#
# $1 = OUT directory; $2 = label for this read (for example start or end).
set -euo pipefail
OUT="$1"; LABEL="$2"
PORT="${PROM_PORT:-19092}"
mkdir -p "$OUT/raw/$LABEL"
echo "-- $(date -u +%Y-%m-%dT%H:%M:%SZ) exposition read '$LABEL' begins" >&2
echo "-- port-forward opened at $(date -u +%Y-%m-%dT%H:%M:%SZ): kubectl -n telemetry port-forward svc/prometheus ${PORT}:9090" >&2
kubectl -n telemetry port-forward svc/prometheus "${PORT}:9090" >/dev/null 2>&1 &
PF=$!
close_pf() { if [ -n "${PF:-}" ]; then kill "$PF" 2>/dev/null || true; wait "$PF" 2>/dev/null || true; PF=""; echo "-- port-forward closed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2; fi; }
trap close_pf EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:${PORT}/-/ready" >/dev/null 2>&1 && break; sleep 0.25; done
curl -sf "http://127.0.0.1:${PORT}/api/v1/targets?state=active" > "$OUT/raw/$LABEL/targets.json"
close_pf
jq -r '.data.activeTargets[] | [.labels.job, .scrapeUrl, (.discoveredLabels.__meta_kubernetes_namespace // ""), (.discoveredLabels.__meta_kubernetes_pod_name // ""), (.labels.gateway_name // "")] | @tsv' \
	"$OUT/raw/$LABEL/targets.json" | sort > "$OUT/raw/$LABEL/targets.tsv"
while IFS=$'\t' read -r job url ns pod gw; do
	hostport="${url#http://}"; hostport="${hostport%%/*}"; port="${hostport##*:}"
	if [ -n "$pod" ]; then
		name="${job}_${pod}"
		path="/api/v1/namespaces/${ns}/pods/${pod}:${port}/proxy/metrics"
	else
		host="${hostport%%:*}"; svc="${host%%.*}"; sns="$(echo "$host" | cut -d. -f2)"
		name="${job}_${svc}"
		path="/api/v1/namespaces/${sns}/services/${svc}:${port}/proxy/metrics"
	fi
	if kubectl get --raw "$path" > "$OUT/raw/$LABEL/${name}.prom" 2>"$OUT/raw/$LABEL/${name}.err"; then
		echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) read ${job} ${pod:-$url} via ${path}: $(grep -c '' "$OUT/raw/$LABEL/${name}.prom") lines" >&2
	else
		echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED ${job} ${pod:-$url} via ${path}: $(cat "$OUT/raw/$LABEL/${name}.err")" >&2
	fi
	printf '%s\t%s\t%s\t%s\n' "$job" "$name" "${gw:-${pod:-$url}}" "$path" >> "$OUT/raw/$LABEL/read.tsv"
done < "$OUT/raw/$LABEL/targets.tsv"
python3 - "$OUT/raw/$LABEL" > "$OUT/families-$LABEL.csv" <<'PY'
import csv, os, re, sys
d = sys.argv[1]
rows = []
for line in open(os.path.join(d, "read.tsv")):
    job, name, who, path = line.rstrip("\n").split("\t")
    p = os.path.join(d, name + ".prom")
    types, labels, samples = {}, {}, {}
    for l in open(p, errors="replace"):
        if l.startswith("# TYPE "):
            _, _, fam, typ = l.split(None, 3)
            types[fam] = typ.strip()
            labels.setdefault(fam, set()); samples.setdefault(fam, 0)
            continue
        if not l.strip() or l.startswith("#"):
            continue
        m = re.match(r'([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*?)\})?\s', l)
        if not m:
            continue
        sname = m.group(1)
        fam = sname
        for suf in ("_total", "_bucket", "_count", "_sum", "_created", "_info"):
            if sname not in types and sname.endswith(suf) and sname[: -len(suf)] in types:
                fam = sname[: -len(suf)]
                break
        labels.setdefault(fam, set()); samples[fam] = samples.get(fam, 0) + 1
        for k in re.findall(r'([a-zA-Z_][a-zA-Z0-9_]*)="', m.group(3) or ""):
            labels[fam].add(k)
    for fam in sorted(set(types) | set(labels)):
        rows.append({"job": job, "target": who, "family": fam, "type": types.get(fam, "(no TYPE line)"),
                     "labels": "|".join(sorted(labels.get(fam, set()))), "samples": samples.get(fam, 0)})
w = csv.DictWriter(sys.stdout, fieldnames=["job", "target", "family", "type", "labels", "samples"], lineterminator="\n")
w.writeheader()
for r in rows:
    w.writerow(r)
PY
echo "-- $(date -u +%Y-%m-%dT%H:%M:%SZ) exposition read '$LABEL' done: $(($(grep -c '' "$OUT/families-$LABEL.csv") - 1)) family rows in $OUT/families-$LABEL.csv" >&2
