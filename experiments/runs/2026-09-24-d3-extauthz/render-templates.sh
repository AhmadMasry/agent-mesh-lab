#!/usr/bin/env bash
# Follow-on D-3: why the extauthz pod did not roll at step 2c and step 3 while the worker and the mock did. Renders each
# step's overlay at the checked-out tree and compares each Deployment's pod template (.spec.template) between
# consecutive steps, byte for byte, printing the lines that differ. Reads only; applies nothing.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STEPS=(step-1-nomesh step-2-ambient-agw step-2b-agw-ingress-egress step-2c-gate2 step-3-stress)
for s in "${STEPS[@]}"; do
	kubectl kustomize "deploy/$s" > "$T/$s.yaml"
	for d in extauthz worker mockllm orchestrator; do
		yq "select(.kind == \"Deployment\" and .metadata.name == \"$d\") | .spec.template" "$T/$s.yaml" > "$T/$s-$d.tpl"
	done
done
echo "# pod templates of each Deployment, consecutive steps, rendered $(date -u +%FT%TZ) from the checked-out deploy subtree $(git rev-parse HEAD:deploy)"
echo "# (the built commit b45cafdd's deploy subtree is $(git rev-parse b45cafdd:deploy): $([ "$(git rev-parse HEAD:deploy)" = "$(git rev-parse b45cafdd:deploy)" ] && echo equal || echo DIFFERENT))"
for d in extauthz worker mockllm orchestrator; do
	for i in 0 1 2 3; do
		a=${STEPS[$i]}; b=${STEPS[$((i + 1))]}
		if [ ! -s "$T/$a-$d.tpl" ] || [ "$(cat "$T/$a-$d.tpl")" = "null" ]; then echo "$d $a -> $b: absent at $a"; continue; fi
		if cmp -s "$T/$a-$d.tpl" "$T/$b-$d.tpl"; then echo "$d $a -> $b: identical"; else
			echo "$d $a -> $b: DIFFERS"; { diff "$T/$a-$d.tpl" "$T/$b-$d.tpl" || true; } | grep '^[<>]' | sed 's/^/    /'; fi
	done
done
