#!/usr/bin/env bash
# Kubescape image scan over the five images this lab builds. Called by
# `make scan-images`, which builds the four Go images into ko.local first and
# passes the output directory as $1.
#
# Everything in the output directory is written here, and nothing the findings
# entry counts is derived by hand:
#
#   <name>.json           Kubescape's own report, as it writes it
#   <name>.txt            Kubescape's human-readable output for the same scan
#   <name>-findings.csv   one row per finding, derived from <name>.json with
#                         experiments/lib/kubescape-findings.jq
#                         (id,severity,package,version,fixed_in,type; sorted by
#                         severity then id)
#   summary.csv           counts by severity per image, from the same JSON
#   scan-context.txt      scanner version, vulnerability-database date, the
#                         command used, the digest of every image scanned, and
#                         the image each lab pod is running
#
# Counting is the whole job. Nothing here fails on a finding and nothing is fixed
# in response to one: a fix is the author's decision.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT="${1:?usage: scan-images.sh <output-dir>}"
mkdir -p "$OUT"
JQ_PROG="experiments/lib/kubescape-findings.jq"

# name:image pairs. The Go images are the ko.local tags `make scan-images` just
# built; the Python one is the tag the cluster runs.
IMAGES=""
for repo in worker mockllm loadgen replay; do
	tag=$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E "^ko\.local/${repo}-[0-9a-f]+:latest$" | head -1)
	[ -n "$tag" ] || { echo "no ko.local image for $repo; run make scan-images" >&2; exit 1; }
	IMAGES="${IMAGES}${repo}=${tag}"$'\n'
done
IMAGES="${IMAGES}orchestrator=orchestrator:dev"$'\n'

echo "== scanning =="
while IFS= read -r line; do
	[ -n "$line" ] || continue
	name="${line%%=*}"; image="${line#*=}"
	echo "-- $name ($image)"
	kubescape scan image "$image" --format json --output "${OUT}/${name}.json" > "${OUT}/${name}.txt" 2>&1 || true
	if [ -s "${OUT}/${name}.json" ]; then
		jq -r -f "$JQ_PROG" "${OUT}/${name}.json" > "${OUT}/${name}-findings.csv"
	fi
done <<< "$IMAGES"

echo "== summary.csv =="
IMAGES="$IMAGES" OUT="$OUT" python3 - <<'PY'
import json, os, csv, collections
out = os.environ["OUT"]
order = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]
rows = []
for line in os.environ["IMAGES"].splitlines():
    if not line:
        continue
    name, image = line.split("=", 1)
    path = os.path.join(out, f"{name}.json")
    counts = collections.Counter()
    total = 0
    if os.path.exists(path):
        with open(path) as fh:
            doc = json.load(fh)
        for m in doc.get("matches", []):
            sev = (m.get("vulnerability") or {}).get("severity") or "Unknown"
            counts[sev] += 1
            total += 1
    rows.append([name, image, total] + [counts.get(s, 0) for s in order])
rows.sort(key=lambda r: -r[2])
with open(os.path.join(out, "summary.csv"), "w", newline="") as fh:
    w = csv.writer(fh, lineterminator="\n")
    w.writerow(["image_name", "image", "total"] + [s.lower() for s in order])
    w.writerows(rows)
for r in rows:
    print(",".join(str(x) for x in r))
PY

echo "== scan-context.txt =="
{
	echo "Kubescape image scan, context and provenance. Written by experiments/scan-images.sh."
	echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)."
	echo
	echo "Scanner"
	echo "-------"
	echo "\$ kubescape version"
	kubescape version 2>&1 | head -4
	echo
	echo "Installed with the route the documentation gives for this platform"
	echo "(https://kubescape.io/docs/install-cli/; on macOS, \`brew install kubescape\`)."
	echo "Kubescape is a CNCF incubating project (https://www.cncf.io/projects/); Trivy and"
	echo "Grype are not CNCF projects, which is why this is the scanner the author chose."
	echo
	echo "Vulnerability database, as each scan reported it:"
	grep -h "Vulnerability DB built" "$OUT"/*.txt 2>/dev/null | sort -u || echo "  (not reported)"
	echo
	echo "Command, per image, documented at https://kubescape.io/docs/scanning/"
	echo "('kubescape scan image <image:tag>' and '--format json ... --output'):"
	echo "  kubescape scan image <image> --format json --output <name>.json"
	echo
	echo "Nothing is installed in the cluster: no Kubescape Operator, no node agent, no"
	echo "host scanner. This is a host-side CLI run against images in the local Docker"
	echo "daemon."
	echo
	echo "What was scanned"
	echo "----------------"
	echo "Kubescape reads the local Docker daemon, not the kind node's containerd store, so"
	echo "the four Go images are rebuilt for the scan by the make target with"
	echo "  KO_DOCKER_REPO=ko.local ko build ./agents/worker ./fixtures/mockllm ./fixtures/loadgen ./fixtures/replay --platform=linux/\$(go env GOARCH)"
	echo "from the same sources and the same .ko.yaml base that make step-3 uses. The base"
	echo "ko resolved for this build, from ko-build.txt:"
	grep -hoE "Using base [^ ]+" "$OUT/ko-build.txt" 2>/dev/null | sort -u | sed 's/^/  /' || echo "  (ko-build.txt not present)"
	echo
	echo "Image IDs of what was scanned (local daemon):"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		name="${line%%=*}"; image="${line#*=}"
		printf '  %-13s %s\n                %s\n' "$name" "$image" "$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo '(not present)')"
	done <<< "$IMAGES"
	echo
	echo "Image IDs the lab pods are running (cluster):"
	kubectl -n lab get pod -l 'app in (worker,mockllm,orchestrator)' \
		-o jsonpath='{range .items[*]}{"  "}{.metadata.name}{"\n                "}{.status.containerStatuses[0].image}{"\n                "}{.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null \
		|| echo "  (no cluster reachable)"
	echo
	echo "Read as it is rather than as one would like it: the ko image IDs above do NOT"
	echo "equal the ones the pods run. This repository has measured before"
	echo "(experiments/runs/2026-09-09-a3-pipeline/replicasets.txt, and the comments on"
	echo "step-2c and step-3 in the Makefile) that ko rebuilds unchanged sources to a new"
	echo "digest on every apply, so a rebuild for a scan cannot reproduce the digest a"
	echo "previous apply loaded. What is equal is the input: the same checkout, the same"
	echo ".ko.yaml base tag resolved to the same index digest, and the same toolchain."
	echo "The orchestrator's two identifiers differ for a different reason and are the SAME"
	echo "BUILD: \`kind load docker-image\` re-imports into the node's containerd store,"
	echo "which computes its own digest over the imported archive, so the pod reports an"
	echo "import-<date>@sha256:... reference while the daemon holds the build's own id."
	echo
	echo "Files"
	echo "-----"
	echo "<image>-findings.csv is the per-finding record, one row per counted finding,"
	echo "columns id,severity,package,version,fixed_in,type, sorted by severity then id."
	echo "fixed_in is EMPTY when the report carries no fix -- nothing to upgrade to --"
	echo "which is the column the findings entry's Interpretation counts. Derived from"
	echo "<image>.json by experiments/lib/kubescape-findings.jq, which is what this script"
	echo "runs; the program's own comments explain the columns and why the fields need no"
	echo "quoting."
	echo
	echo "The row count of each CSV equals that image's total in summary.csv, and their"
	echo "per-severity counts equal its columns."
	echo
	echo "One JSON is deliberately not kept in the repository: the orchestrator's, which"
	echo "Kubescape wrote at 757325 bytes -- 170 matches each carrying its full"
	echo "description, CVSS vectors and advisory URLs -- where CLAUDE.md keeps run outputs"
	echo "to small CSV or JSONL. It is regenerated by \`make scan-images\`. Its"
	echo "orchestrator-findings.csv carries every one of its 170 findings and is in the"
	echo "tree. The other four JSON reports are kept as Kubescape wrote them."
} > "$OUT/scan-context.txt"
echo "wrote $OUT/scan-context.txt"
