#!/usr/bin/env bash
# B-4, the Job template's CANCEL_AFTER_MS: every render of every script that renders deploy/base/loadgen-a2-job.yaml.
# For each script, its own sed block (the lines from `sed -e "s/\${LWI}` to `"$JOB_TEMPLATE" \`), taken from the
# parent's copy (the commit before the template change) and from this tree's, is run over each template with the
# knob values its rows render, and the two outputs are compared. Nothing is sent: the pipe to ko is cut off at the
# template line. Adapted from experiments/runs/2026-09-21-b3-streaming-client/code-proof/render/render.sh, changed in
# this header, the scratch path and the last section (B-3's own row driver over the new template).
#   bash render.sh <parent revision> <tip revision | WORKTREE>
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PARENT_REV="$1"; TIP_REV="$2"
R="${TMPDIR%/}/b4/render"
rm -rf "$R" && mkdir -p "$R/parent/deploy/base" "$R/tip/deploy/base"
for f in experiments/gate2-a2.sh experiments/gate3-matrix.sh deploy/base/loadgen-a2-job.yaml deploy/base/loadgen-job.yaml; do
	case "$f" in experiments/*) to="$(basename "$f")" ;; *) to="$f" ;; esac
	git show "$PARENT_REV:$f" > "$R/parent/$to"
	if [ "$TIP_REV" = WORKTREE ]; then cp "$f" "$R/tip/$to"; else git show "$TIP_REV:$f" > "$R/tip/$to"; fi
done
git show 86616dff:experiments/runs/2026-09-21-b3-streaming-client/rows.sh > "$R/b3-rows.sh"
echo "# parent $PARENT_REV ($(git rev-parse --short=8 "$PARENT_REV")), tip $TIP_REV$([ "$TIP_REV" = WORKTREE ] || echo " ($(git rev-parse --short=8 "$TIP_REV"))"); run $(date -u +%FT%TZ)"
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
echo
echo "== not a renderer of any existing row: B-3's own row driver (experiments/runs/2026-09-21-b3-streaming-client/rows.sh),"
echo "== a dated record, unedited. Its apply_job sed block over the tip's template, MODE=stream, TASK_ID empty:"
awk '/^\tsed -e "s\/\^  name: loadgen-/{on=1} on{print} on && /"\$TEMPLATE" \\$/{exit}' "$R/b3-rows.sh" | sed '$ s/ \\$//' > "$R/b3-block.txt"
cat "$R/b3-block.txt"
( lwi="lwi-render-01" name="loadgen-lwi-render-01" target="http://worker.lab.svc.cluster.local:8080" mode=stream task="" TEMPLATE="$R/tip/deploy/base/loadgen-a2-job.yaml"
  eval "$(cat "$R/b3-block.txt")" ) > "$R/b3.yaml"
echo "placeholders left: $(grep -c '\${' "$R/b3.yaml"): $(grep -n '\${' "$R/b3.yaml" | tr -s ' ' | tr '\n' ' ')"
echo "(a Job rendered so would stop before it sends: an unsubstituted CANCEL_AFTER_MS or CLIENT_HOST is refused, TestCancelFromEnv_AnythingElseIsRefused, TestHostFromEnv_AnythingElseIsRefused)"
