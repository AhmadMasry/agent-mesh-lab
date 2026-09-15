#!/usr/bin/env bash
# Follow-ups 12: render every overlay at the base commit and at commit 1's deploy tree, and diff the two.
#
#   experiments/runs/2026-09-15-ingress-namespace/render/render-diff.sh <base-commit> <deploy-tree-id>
#
# Both trees are extracted from git objects into a temporary directory (git archive), not read from the working
# tree, so the record names exactly what was rendered: the base commit's deploy/ and the deploy subtree ID given
# (read from the index with `git write-tree --prefix=deploy/` after staging, which is the subtree the commit
# carries; check it with `git rev-parse <commit>:deploy`). bash 3.2 (macOS /bin/bash) is assumed, hence the
# ${flags[@]+...} form for a possibly empty array under set -u. Renders with `kubectl kustomize`, the command every
# step target uses; the retry overlays with --load-restrictor=LoadRestrictionsNone, as `make retry-on/off` does.
# Writes <overlay>.diff per overlay and summary.txt beside this script. Read-only apart from those files.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
BASE="$1"; TREE="$2"
OUT=experiments/runs/2026-09-15-ingress-namespace/render
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/base" "$TMP/new"
git archive "$BASE" deploy | tar -x -C "$TMP/base"
git archive --prefix=deploy/ "$TREE" | tar -x -C "$TMP/new"
OVERLAYS="base step-1-nomesh step-2-ambient-agw step-2b-agw-ingress-egress step-2c-gate2 step-3-stress"
RETRY="step-3-stress/retry/waypoint/off step-3-stress/retry/waypoint/on step-3-stress/retry/ingress/off step-3-stress/retry/ingress/on step-3-stress/retry/egress/off step-3-stress/retry/egress/on"
objects() { # file -> one line per object: kind namespace/name
	awk '/^---$/ {if (k!="") print k" "(ns==""?"-":ns)"/"n; k=""; n=""; ns=""; inmeta=0; next}
	     /^kind: / {k=$2}
	     /^metadata:/ {inmeta=1; next}
	     inmeta && /^  name: / {n=$2}
	     inmeta && /^  namespace: / {ns=$2}
	     inmeta && /^[^ ]/ {inmeta=0}
	     END {if (k!="") print k" "(ns==""?"-":ns)"/"n}' "$1" | sort
}
{
echo "# Follow-ups 12: overlay renders at the base commit and at commit 1's deploy tree, $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "# base:   $BASE ($(git rev-parse "$BASE")) deploy $(git rev-parse "$BASE:deploy")"
echo "# target: deploy tree $TREE"
echo "# $(kubectl version --client 2>/dev/null | head -1) (kubectl kustomize)"
echo
for o in $OVERLAYS $RETRY; do
	f=$(printf '%s' "$o" | tr '/' '_')
	case "$o" in step-3-stress/retry/*) flags=(--load-restrictor=LoadRestrictionsNone) ;; *) flags=() ;; esac
	(cd "$TMP/base" && kubectl kustomize ${flags[@]+"${flags[@]}"} "deploy/$o") > "$TMP/$f.base.yaml" 2> "$TMP/$f.base.err"; rb=$?
	(cd "$TMP/new" && kubectl kustomize ${flags[@]+"${flags[@]}"} "deploy/$o") > "$TMP/$f.new.yaml" 2> "$TMP/$f.new.err"; rn=$?
	diff -u --label "d28dea6 $o" --label "commit-1 $o" "$TMP/$f.base.yaml" "$TMP/$f.new.yaml" > "$OUT/$f.diff"; rd=$?
	nb=$(objects "$TMP/$f.base.yaml" | grep -c .); nn=$(objects "$TMP/$f.new.yaml" | grep -c .)
	echo "## $o"
	echo "   render exit: base $rb, target $rn; objects: base $nb, target $nn; sha256 base $(shasum -a 256 < "$TMP/$f.base.yaml" | cut -c1-16) target $(shasum -a 256 < "$TMP/$f.new.yaml" | cut -c1-16)"
	if [ "$rb" -ne 0 ] || [ "$rn" -ne 0 ]; then
		echo "   RENDER FAILED: base stderr: $(tr '\n' ' ' < "$TMP/$f.base.err") target stderr: $(tr '\n' ' ' < "$TMP/$f.new.err")"
	elif [ "$rd" -eq 0 ]; then
		echo "   renders identical"; rm -f "$OUT/$f.diff"
	else
		echo "   diff: $(grep -c '^-[^-]' "$OUT/$f.diff") line(s) removed, $(grep -c '^+[^+]' "$OUT/$f.diff") added -> $f.diff"
		echo "   objects only at base:   $(comm -23 <(objects "$TMP/$f.base.yaml") <(objects "$TMP/$f.new.yaml") | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
		echo "   objects only at target: $(comm -13 <(objects "$TMP/$f.base.yaml") <(objects "$TMP/$f.new.yaml") | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
	fi
done
echo
echo "## the agentgateway control-plane chart, which the overlays do not carry: helm template of"
echo "## oci://cr.agentgateway.dev/charts/agentgateway v1.5.0 with each tree's agentgateway-values.yaml, as make step-2b passes it"
V=deploy/step-2b-agw-ingress-egress/agentgateway-values.yaml
helm template agentgateway oci://cr.agentgateway.dev/charts/agentgateway --namespace agentgateway-system --version v1.5.0 -f "$TMP/base/$V" > "$TMP/chart.base.yaml" 2> "$TMP/chart.base.err"; cb=$?
helm template agentgateway oci://cr.agentgateway.dev/charts/agentgateway --namespace agentgateway-system --version v1.5.0 -f "$TMP/new/$V" > "$TMP/chart.new.yaml" 2> "$TMP/chart.new.err"; cn=$?
helm template agentgateway oci://cr.agentgateway.dev/charts/agentgateway --namespace agentgateway-system --version v1.5.0 > "$TMP/chart.none.yaml" 2>/dev/null
diff -u --label "d28dea6 chart render" --label "commit-1 chart render" "$TMP/chart.base.yaml" "$TMP/chart.new.yaml" > "$OUT/agentgateway-chart.diff"
echo "   helm: $(helm version --short); render exit: base $cb, target $cn; chart pulled: $(grep -h '^Digest' "$TMP/chart.new.err" | head -1)"
echo "   objects: base $(objects "$TMP/chart.base.yaml" | grep -c .), target $(objects "$TMP/chart.new.yaml" | grep -c .)"
echo "   diff: $(grep -c '^-[^-]' "$OUT/agentgateway-chart.diff") line(s) removed, $(grep -c '^+[^+]' "$OUT/agentgateway-chart.diff") added -> agentgateway-chart.diff"
grep '^[-+][^-+]' "$OUT/agentgateway-chart.diff" | sed 's/^/      /'
echo "   target render vs a render with no values file: $(cmp -s "$TMP/chart.new.yaml" "$TMP/chart.none.yaml" && echo identical || echo DIFFERENT)"
echo "   the label istio.io/dataplane-mode in the render: base $(grep -c 'istio.io/dataplane-mode' "$TMP/chart.base.yaml"), target $(grep -c 'istio.io/dataplane-mode' "$TMP/chart.new.yaml")"
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
