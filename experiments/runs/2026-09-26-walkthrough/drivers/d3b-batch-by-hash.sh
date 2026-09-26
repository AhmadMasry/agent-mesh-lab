#!/usr/bin/env bash
# Follow-on D-3b: the batch probes' receiver lines, found by the body hash the client recorded (as D-3 did: a batch carries
# no identity in its body and the receivers' ledgers take none from the header for a batch). For each batch send under
# deny/ and allow/, every ingress-ledger line of the receiver it addressed (kubectl logs of the receiver, read once when
# this script ran) whose body_sha256 equals the client's, written to ingress-by-body-hash.txt in the send's directory with
# the field source set to the receiver, as make ledgers writes its collections.
# Reads only. No retry. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
D=experiments/runs/2026-09-26-walkthrough/d3b
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
kubectl -n lab logs deploy/worker --tail=-1 2>/dev/null | grep '"ledger":"ingress"' > "$T/worker"
kubectl -n lab logs deploy/orchestrator --tail=-1 2>/dev/null | grep '"ledger":"ingress"' > "$T/orchestrator"
echo "# read $(date -u +%FT%TZ): worker $(wc -l < "$T/worker" | tr -d ' ') ingress lines, orchestrator $(wc -l < "$T/orchestrator" | tr -d ' ')"
for w in "$D"/deny/*-batch-* "$D"/allow/*-batch-*; do
	case "$w" in *-go-batch-*) src=worker ;; *) src=orchestrator ;; esac
	h=$(jq -r '.body_sha256' "$w/client.jsonl")
	{ grep -F "\"body_sha256\":\"$h\"" "$T/$src" || true; } | jq -c --arg s "$src" '. + {source: $s}' > "$w/ingress-by-body-hash.txt"
	echo "$(basename "$w") $src sha256=$h lines=$(grep -c . "$w/ingress-by-body-hash.txt")"
done
