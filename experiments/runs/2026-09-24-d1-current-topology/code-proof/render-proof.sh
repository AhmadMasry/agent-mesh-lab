#!/usr/bin/env bash
# D-1 code proof: the render proof for the manifest commit. Every kustomization under deploy/ rendered with kubectl
# kustomize (--load-restrictor=LoadRestrictionsNone, as the Makefile renders the retry sets) and the three Job
# templates rendered with every placeholder any script substitutes, at the parent of the manifest commit and at the
# manifest commit, both taken by git archive; then compared, file by file, and the three settings read per
# Deployment. Reads the repository only; renders into the scratch directory given.
#   bash render-proof.sh <parent commit> <commit> <scratch dir>
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
P="$1"; C="$2"; S="$3"
rm -rf "$S" && mkdir -p "$S/parent" "$S/tree"
git archive "$P" deploy | tar -x -C "$S/parent"
git archive "$C" deploy | tar -x -C "$S/tree"
echo "# render proof: parent $(git rev-parse "$P") vs $(git rev-parse "$C"), deploy trees $(git rev-parse "$P:deploy") vs $(git rev-parse "$C:deploy")"
for side in parent tree; do
	for k in $(cd "$S/$side" && find deploy -name kustomization.yaml | sort); do
		d=$(dirname "$k")
		kubectl kustomize --load-restrictor=LoadRestrictionsNone "$S/$side/$d" > "$S/$side/$(echo "$d" | tr / _).out" 2>&1 || echo "RENDER FAILED $side $d"
	done
	for j in loadgen-job loadgen-a2-job replay-job; do
		LWI=w TARGET_URL=http://t CLIENT_RETRIES=0 CLIENT_RETRY_ON=transport CLIENT_SDK_RESEND=off CLIENT_DIAL=target \
			CLIENT_HOST=h GAP_MS=0 MODE=stream TASK_ID=t CANCEL_AFTER_MS=5 envsubst < "$S/$side/deploy/base/$j.yaml" > "$S/$side/job_$j.out"
	done
done
n=0
for f in $(cd "$S/parent" && ls *.out); do
	n=$((n + 1))
	if cmp -s "$S/parent/$f" "$S/tree/$f"; then echo "same     $f"; else
		echo "DIFFERS  $f, non-comment lines: $(diff <(grep -v '^ *#' "$S/parent/$f") <(grep -v '^ *#' "$S/tree/$f") | grep '^[<>]' | tr -s ' ' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
	fi
done
echo "# renders: $n"
echo "# placeholders left outside a comment in the tree's renders: $(cat "$S"/tree/*.out | grep -v '^ *#' | grep -c '\${' || true)"
echo "# the three settings per Deployment, in each render of the tree that holds the agents:"
for f in "$S"/tree/deploy_*.out; do
	r=$(awk '/^kind: Deployment/{k=1} /^kind:/{if($2!="Deployment")k=0} k&&/^  name:/{name=$2} k&&/- name: (REFUSE_OPERATION|LEDGER_HEADERS|FORWARD_RESUBSCRIBE)/{e=$3; getline; printf "%s:%s=%s ", name, e, $2}' "$f")
	[ -n "$r" ] && echo "  $(basename "$f"): $r"
done
echo "# files under deploy/ that differ: $(git diff --name-only "$P" "$C" -- deploy | tr '\n' ' ')"
echo "# scripts under experiments/ (not runs/) that differ: $(git diff --name-only "$P" "$C" -- experiments ':!experiments/runs' | wc -l | tr -d ' ')"
echo "# scripts that set either setting: $(git grep -l 'LEDGER_HEADERS\|FORWARD_RESUBSCRIBE' "$C" -- Makefile 'experiments/*.sh' experiments/lib | wc -l | tr -d ' ')"
