#!/usr/bin/env bash
# Follow-ups 11 / commit 1: every setting the retired istioctl installation route carried,
# found in the Helm values files, before deploy/step-2-ambient-agw/istio-meshconfig.yaml is
# deleted. Read-only; no cluster involved. Run from the repository root at the parent of the
# commit that deletes the file (the file is gone after it): yq and jq read the files, awk cuts
# the meshConfig blocks as text, shasum hashes them.
#
# The route had two inputs, not one, and both are covered:
#   1. the IstioOperator file, every leaf of which is listed (apiVersion and kind name the API
#      and set nothing);
#   2. the recipe's own `--set` flags, read from the Makefile line that ran it:
#      istioctl install --set profile=ambient --set values.pilot.env.PILOT_ENABLE_AGENTGATEWAY=true -f <file> -y
set -euo pipefail
OP=deploy/step-2-ambient-agw/istio-meshconfig.yaml
IV=deploy/step-2-ambient-agw/istio-values.yaml
ZV=deploy/step-2-ambient-agw/ztunnel-values.yaml

leaves() { yq -o=json '[.. | select((tag != "!!map" and tag != "!!seq") or length == 0) | {"path": (path | join(".")), "value": .}]' "$1" | jq -r '.[] | "\(.path)\t\(.value | tojson)"'; }
get() { # file, dotted path -> JSON value or <absent>
	local v
	v=$(yq -o=json ".$2" "$1")
	if [ "$v" = "null" ]; then echo "<absent>"; else printf '%s' "$v" | jq -c .; fi
}

echo "# Every setting of the retired istioctl installation route, beside the Helm values file that carries it."
echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by experiments/runs/2026-09-15-helm-only/operator-file-coverage.sh"
st=$(git status --short -- deploy/step-2-ambient-agw Makefile)
echo "# at HEAD $(git rev-parse HEAD) with \`git status --short -- deploy/step-2-ambient-agw Makefile\` -> ${st:-(empty)}"
echo "# blobs: $OP $(git rev-parse HEAD:$OP); $IV $(git rev-parse HEAD:$IV); $ZV $(git rev-parse HEAD:$ZV)"
echo
echo "## 1. the recipe line the route ran (Makefile, at this HEAD)"
grep -n 'istioctl install' Makefile | grep -v '^[0-9]*:\s*#' | grep -v 'echo' | sed 's/^/   /'
echo
echo "## 2. key-by-key table"
printf '   %-3s %-104s %-46s %-96s %-46s %s\n' "#" "retired route: source and key" "value" "Helm route: file and key" "value" "result"
n=0; missing=0
row() { # label, value, helm file, helm key
	n=$((n+1))
	local hv; hv=$(get "$3" "$4")
	local res="EQUAL"; [ "$hv" = "$2" ] || { res="NOT FOUND OR DIFFERENT"; missing=$((missing+1)); }
	printf '   %-3s %-104s %-46s %-96s %-46s %s\n' "$n" "$1" "$2" "$(basename "$3") $4" "$hv" "$res"
}
while IFS=$'\t' read -r path value; do
	case "$path" in
		apiVersion|kind) continue ;;
		spec.values.pilot.env.*)   row "istio-meshconfig.yaml $path" "$value" "$IV" "pilot.env.${path#spec.values.pilot.env.}" ;;
		spec.values.ztunnel.env.*) row "istio-meshconfig.yaml $path" "$value" "$ZV" "env.${path#spec.values.ztunnel.env.}" ;;
		spec.meshConfig.*)         row "istio-meshconfig.yaml $path" "$value" "$IV" "${path#spec.}" ;;
		*) n=$((n+1)); missing=$((missing+1)); printf '   %-3s %-104s %-46s %s\n' "$n" "istio-meshconfig.yaml $path" "$value" "NO MAPPING -- a Stop" ;;
	esac
done < <(leaves "$OP")
row "recipe --set profile=ambient (istiod)" '"ambient"' "$IV" "profile"
row "recipe --set profile=ambient (ztunnel)" '"ambient"' "$ZV" "profile"
row "recipe --set values.pilot.env.PILOT_ENABLE_AGENTGATEWAY=true" '"true"' "$IV" "pilot.env.PILOT_ENABLE_AGENTGATEWAY"
n=$((n+1))
cni=$(grep -c 'helm upgrade -i istio-cni cni .*' Makefile || true)
cniset=$(grep -A1 'helm upgrade -i istio-cni cni' Makefile | grep -c -- '--set profile=ambient' || true)
if [ "$cniset" = 1 ]; then cnires=EQUAL; else cnires="NOT FOUND"; missing=$((missing+1)); fi
printf '   %-3s %-104s %-46s %-96s %-46s %s\n' "$n" "recipe --set profile=ambient (cni)" '"ambient"' "Makefile step-2: helm upgrade -i istio-cni ... --set profile=ambient" "lines=$cni with-flag=$cniset" "$cnires"
echo
echo "   settings on the retired route: $n; not found on the Helm route: $missing"
echo
echo "## 3. the converse: every setting in the two values files, and where the retired route had it"
while IFS=$'\t' read -r path value; do
	case "$path" in
		profile)          from="recipe --set profile=ambient" ;;
		pilot.env.PILOT_ENABLE_AGENTGATEWAY) from="recipe --set values.pilot.env.PILOT_ENABLE_AGENTGATEWAY=true" ;;
		pilot.env.*)      from="istio-meshconfig.yaml spec.values.$path" ;;
		meshConfig.*)     from="istio-meshconfig.yaml spec.$path" ;;
		*)                from="NOT ON THE RETIRED ROUTE" ;;
	esac
	printf '   %-96s %-46s <- %s\n' "istio-values.yaml $path" "$value" "$from"
done < <(leaves "$IV")
while IFS=$'\t' read -r path value; do
	case "$path" in
		profile) from="recipe --set profile=ambient" ;;
		env.*)   from="istio-meshconfig.yaml spec.values.ztunnel.$path" ;;
		*)       from="NOT ON THE RETIRED ROUTE" ;;
	esac
	printf '   %-96s %-46s <- %s\n' "ztunnel-values.yaml $path" "$value" "$from"
done < <(leaves "$ZV")
echo
echo "## 4. the meshConfig block, byte for byte"
echo "# The IstioOperator carries it at spec.meshConfig, two spaces deeper; istio-values.yaml at the top"
echo "# level. Each block is cut as text from its 'meshConfig:' line to the next line at that line's"
echo "# indentation or shallower (end of file in both), comment lines dropped, and the operator file's"
echo "# block dedented by exactly two spaces. Nothing else is changed before hashing."
cut_block() { # file, indent
	awk -v ind="$2" '
		function depth(s) { match(s, /^ */); return RLENGTH }
		!on && $0 ~ "^" ind "meshConfig:" { on=1; print substr($0, length(ind)+1); next }
		on && /^[[:space:]]*#/ { next }
		on && /^[[:space:]]*$/ { next }
		on && depth($0) <= length(ind) { on=0 }
		on { print substr($0, length(ind)+1) }
	' "$1"
}
A=$(cut_block "$OP" "  "); B=$(cut_block "$IV" "")
echo; echo "### $OP, spec.meshConfig, dedented by 2"; printf '%s\n' "$A" | sed 's/^/   |/'
ha=$(printf '%s\n' "$A" | shasum -a 256 | cut -d' ' -f1); echo "   sha256 = $ha"
echo; echo "### $IV, meshConfig"; printf '%s\n' "$B" | sed 's/^/   |/'
hb=$(printf '%s\n' "$B" | shasum -a 256 | cut -d' ' -f1); echo "   sha256 = $hb"
echo; if [ "$ha" = "$hb" ]; then echo "   result: EQUAL"; else echo "   result: DIFFERENT -- a Stop"; fi
echo
echo "## 5. MAX_WORKLOAD_CERT_TTL, which neither route sets (versions.yaml key istio-workload-cert-ttl)"
for f in "$OP" "$IV" "$ZV"; do
	c=$(yq -o=json '[.. | select(tag == "!!map") | keys[] | select(. == "MAX_WORKLOAD_CERT_TTL")] | length' "$f")
	printf '   %-52s keys named MAX_WORKLOAD_CERT_TTL = %s\n' "$f" "$c"
done
