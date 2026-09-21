#!/usr/bin/env bash
# For each script, its own sed block (the lines from `sed -e "s/\${LWI}` to `"$JOB_TEMPLATE" \`), taken from the
# parent's copy and from this tree's, is run over each template with the knob values its rows render, and the two
# outputs are compared. Nothing is sent: the pipe to ko is cut off at the template line.
set -uo pipefail
R="${TMPDIR%/}/b3/render"
block() { # $1 = script copy -> the sed command, without its trailing pipe
	awk '/^\tsed -e "s\/\\\$\{LWI\}/{on=1} on{print} on && /"\$JOB_TEMPLATE" \\$/{exit}' "$1" | sed '$ s/ \\$//'
}
render() { # $1 = side (parent|tip), $2 = script, $3 = template, then knob values
	local side="$1" script="$2" tpl="$3"
	local lwi="lwi-render-01" TARGET_URL="http://worker.lab.svc.cluster.local:8080" RECEIVER_URL="http://worker.lab.svc.cluster.local:8080"
	local JOB_RETRIES="$4" JOB_SDK_RESEND="$5" JOB_RETRY_ON="$6" JOB_DIAL="$7" JOB_TEMPLATE="$R/$side/deploy/base/$tpl"
	eval "$(block "$R/$side/$script")"
}
n=0; same=0
for script in gate2-a2.sh gate3-matrix.sh; do
	echo "== $script: the sed block, parent then tip =="
	block "$R/parent/$script"; echo "--"; block "$R/tip/$script"
	for tpl in loadgen-a2-job.yaml loadgen-job.yaml; do
		[ "$script" = gate3-matrix.sh ] && [ "$tpl" = loadgen-job.yaml ] && continue
		while read -r r s o d; do
			[ "$d" = "-" ] && d=""
			n=$((n + 1))
			render parent "$script" "$tpl" "$r" "$s" "$o" "$d" > "$R/p.yaml"
			render tip "$script" "$tpl" "$r" "$s" "$o" "$d" > "$R/t.yaml"
			left=$(grep -c '\${' "$R/t.yaml")
			if cmp -s "$R/p.yaml" "$R/t.yaml"; then
				same=$((same + 1)); echo "$script $tpl knobs=[$r $s $o ${d:-<empty>}]: byte-identical; placeholders left in the tip render: $left"
			else
				echo "$script $tpl knobs=[$r $s $o ${d:-<empty>}]: differs, non-comment lines only (placeholders left in the tip render: $left):"
				diff <(grep -v '^[[:space:]]*#' "$R/p.yaml") <(grep -v '^[[:space:]]*#' "$R/t.yaml") | sed 's/^/    /'
			fi
		done <<'KNOBS'
0 off transport -
1 off transport+503 -
0 on transport -
2 off transport -
0 off transport target
1 off transport+503 target
KNOBS
	done
done
echo "renders compared: $n; byte-identical: $same"
