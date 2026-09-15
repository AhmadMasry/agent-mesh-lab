#!/usr/bin/env bash
# Follow-ups 11 / commit 1: does the Helm route of `make step-3` carry every object the retired
# overlay deploy/step-3-stress-nohelm carried? Rendered on this host; no cluster involved.
#
# Run from the repository root at the parent of the commit that deletes the overlay (it is gone
# after it). Renders four streams into a temporary directory, records each one's sha256, and hands
# them to nohelm-coverage.py, which does the object-by-object comparison:
#
#   kubectl kustomize deploy/step-3-stress-nohelm             the retired route's whole step-3 render
#   kubectl kustomize deploy/step-3-stress                    the Helm route's overlay render
#   helm template ... opentelemetry-collector / jaeger / prometheus, with the values files and the
#   chart versions and repositories the Makefile pins, in namespace telemetry, as `make step-3` runs
#   them (helm template rather than upgrade -i; same release names, charts, versions, -n and -f)
#
# The followups-9 record experiments/runs/2026-09-12-helm-first/chart-vs-manifest.txt is the
# precedent for the comparison; it is re-taken here, not cited.
set -euo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mk() { sed -n "s/^$1[[:space:]]*:= *//p" Makefile; }
OTEL_V=$(mk OTEL_COLLECTOR_CHART_VERSION); OTEL_R=$(mk OTEL_COLLECTOR_CHART_REPO)
JAEG_V=$(mk JAEGER_CHART_VERSION);         JAEG_R=$(mk JAEGER_CHART_REPO)
PROM_V=$(mk PROMETHEUS_CHART_VERSION);     PROM_R=$(mk PROMETHEUS_CHART_REPO)
NS=$(mk TELEMETRY_NS)

kubectl kustomize deploy/step-3-stress-nohelm > "$T/nohelm.yaml"
kubectl kustomize deploy/step-3-stress        > "$T/step3.yaml"
helm template otel-collector opentelemetry-collector --repo "$OTEL_R" --version "$OTEL_V" -n "$NS" \
	-f deploy/step-3-stress/otel-collector-values.yaml > "$T/chart-collector.yaml"
helm template jaeger jaeger --repo "$JAEG_R" --version "$JAEG_V" -n "$NS" \
	-f deploy/step-3-stress/jaeger-values.yaml > "$T/chart-jaeger.yaml"
helm template prometheus prometheus --repo "$PROM_R" --version "$PROM_V" -n "$NS" \
	-f deploy/step-3-stress/prometheus-values.yaml > "$T/chart-prometheus.yaml"

for f in nohelm step3 chart-collector chart-jaeger chart-prometheus \
	manifest-otel-collector manifest-jaeger manifest-prometheus; do
	case "$f" in
		manifest-*) src="deploy/step-3-stress-nohelm/${f#manifest-}.yaml" ;;
		*) src="$T/$f.yaml" ;;
	esac
	yq ea -o=json '[.] | map(select(. != null))' "$src" > "$T/$f.json"
done

st=$(git status --short -- deploy Makefile)
echo "# The retired step-3 overlay deploy/step-3-stress-nohelm against the Helm route, object by object."
echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by experiments/runs/2026-09-15-helm-only/nohelm-coverage.sh"
echo "# at HEAD $(git rev-parse HEAD); git status --short -- deploy Makefile -> ${st:-(empty)}"
echo "# deploy subtree $(git rev-parse HEAD:deploy); Makefile blob $(git rev-parse HEAD:Makefile)"
echo "# host tools: $(kubectl version --client 2>/dev/null | head -1); helm $(helm version --short); $(yq --version)"
echo "#"
echo "# rendered streams (sha256 of the bytes each command printed):"
printf '#   %-64s  %s\n' "$(shasum -a 256 "$T/nohelm.yaml" | cut -d' ' -f1)" "kubectl kustomize deploy/step-3-stress-nohelm"
printf '#   %-64s  %s\n' "$(shasum -a 256 "$T/step3.yaml" | cut -d' ' -f1)" "kubectl kustomize deploy/step-3-stress"
printf '#   %-64s  %s\n' "$(shasum -a 256 "$T/chart-collector.yaml" | cut -d' ' -f1)" "helm template otel-collector opentelemetry-collector --repo $OTEL_R --version $OTEL_V -n $NS -f deploy/step-3-stress/otel-collector-values.yaml"
printf '#   %-64s  %s\n' "$(shasum -a 256 "$T/chart-jaeger.yaml" | cut -d' ' -f1)" "helm template jaeger jaeger --repo $JAEG_R --version $JAEG_V -n $NS -f deploy/step-3-stress/jaeger-values.yaml"
printf '#   %-64s  %s\n' "$(shasum -a 256 "$T/chart-prometheus.yaml" | cut -d' ' -f1)" "helm template prometheus prometheus --repo $PROM_R --version $PROM_V -n $NS -f deploy/step-3-stress/prometheus-values.yaml"
echo
python3 "$(dirname "${BASH_SOURCE[0]}")/nohelm-coverage.py" "$T" "$NS"
