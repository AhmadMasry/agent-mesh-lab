#!/usr/bin/env bash
# both-tools.sh <rows dir> -- for every recorded work item under <rows dir>: the layer its own
# attribution.txt holds (written live by the derivation in place when the row ran) beside the layer
# experiments/lib/derive-layer.sh in this checkout derives from the same five files now. Reads only;
# no recorded file is rewritten. CSV on stdout; the reason is last because it holds spaces.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
echo "row,work_item,receiver,deliveries,dispatched,invocations,client_lines,layer_recorded_live,layer_derived_now,same,reason_derived_now"
for d in "$1"/*/a3m-*/; do
	row=$(basename "$(dirname "$d")"); lwi=$(basename "$d")
	case "$row" in *-py*) recv=orchestrator ;; *) recv=worker ;; esac
	old=$(sed -n 's/^layer=//p' "${d}attribution.txt")
	out=$(experiments/lib/derive-layer.sh "$d" "$recv")
	new=$(printf '%s\n' "$out" | sed -n 's/^layer=//p')
	reason=$(printf '%s\n' "$out" | sed -n 's/^reason=//p')
	counts=$(printf '%s\n' "$out" | sed -n 's/^ledgers: deliveries=\([0-9]*\) dispatched=\([0-9]*\) invocations=\([0-9]*\) client_lines=\([0-9]*\)$/\1,\2,\3,\4/p')
	same=no; [ "$old" = "$new" ] && same=yes
	echo "${row},${lwi},${recv},${counts},${old},${new},${same},${reason}"
done
