#!/usr/bin/env bash
# Follow-ups 12 (copied from followups-11 unchanged but for this line): ztunnel policy rejections, per ztunnel pod. Read-only. $1 = output file, $2 = label.
set -uo pipefail
OUT="$1"; LABEL="$2"
{
echo "# ztunnel policy rejections on the rebuilt cluster, ${LABEL}. $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for p in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{"\n"}{end}'); do
	pod=${p%%:*}; node=${p#*:}
	lines=$(kubectl -n istio-system logs "$pod" 2>/dev/null | grep 'policy rejection')
	n=$(printf '%s' "$lines" | grep -c 'policy rejection')
	echo "   ${pod} (${node}): 'policy rejection' lines = ${n}"
	[ -n "$lines" ] && printf '%s\n' "$lines" | sed 's/^/      /'
done
} > "$OUT" 2>&1
cat "$OUT"
