#!/usr/bin/env bash
# Render proof for the REFUSE_OPERATION manifest change: every kustomize overlay
# under deploy/ and every Job template, rendered at the parent commit and at the
# working tree; for each render, the non-comment lines that differ.
set -euo pipefail
REPO=<REPO>
PARENT=${PARENT:?}
OUT=${OUT:?}
rm -rf "$OUT"; mkdir -p "$OUT/parent" "$OUT/tree" "$OUT/renders"
(cd "$REPO" && git archive "$PARENT" deploy experiments | tar -x -C "$OUT/parent")
(cd "$REPO" && tar -c deploy experiments/*.sh | tar -x -C "$OUT/tree")
printf 'parent %s; tree = working tree of %s\n' "$PARENT" "$(cd "$REPO" && git rev-parse --short HEAD)" > "$OUT/summary.txt"
noncomment() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' || true; }
overlays=$(cd "$OUT/tree" && find deploy -name kustomization.yaml -exec dirname {} \; | sort)
for d in $overlays; do
  name=$(echo "$d" | tr '/' '_')
  for side in parent tree; do
    (cd "$OUT/$side" && kubectl kustomize --load-restrictor=LoadRestrictionsNone "$d") > "$OUT/renders/$name.$side.yaml"
  done
  noncomment "$OUT/renders/$name.parent.yaml" > "$OUT/renders/$name.parent.nc"
  noncomment "$OUT/renders/$name.tree.yaml" > "$OUT/renders/$name.tree.nc"
  if cmp -s "$OUT/renders/$name.parent.yaml" "$OUT/renders/$name.tree.yaml"; then
    printf 'kustomize %-50s IDENTICAL\n' "$d" >> "$OUT/summary.txt"
  else
    printf 'kustomize %-50s DIFFERS:\n' "$d" >> "$OUT/summary.txt"
    diff "$OUT/renders/$name.parent.nc" "$OUT/renders/$name.tree.nc" | sed 's/^/    /' >> "$OUT/summary.txt" || true
    printf '    deployments with REFUSE_OPERATION: %s\n' \
      "$(awk '/^kind: Deployment/{k=1} /^---/{k=0} k&&/^  name:/{n=$2} /name: REFUSE_OPERATION/{print n}' "$OUT/renders/$name.tree.yaml" | sort -u | tr '\n' ' ')" >> "$OUT/summary.txt"
  fi
done
# Job templates: every placeholder any script substitutes, filled with one fixed
# value set, so that the parent's and this tree's renders compare byte for byte.
for t in loadgen-job.yaml loadgen-a2-job.yaml replay-job.yaml; do
  for side in parent tree; do
    sed -e 's/${LWI}/c10-render/g' -e 's#${TARGET_URL}#http://worker.lab.svc.cluster.local:8080#g' \
        -e 's/${MODE}//g' -e 's/${TASK_ID}//g' -e 's/${CANCEL_AFTER_MS}//g' -e 's/${CLIENT_HOST}//g' \
        -e 's/${CLIENT_RETRIES}/0/g' -e 's/${CLIENT_SDK_RESEND}/off/g' -e 's/${CLIENT_RETRY_ON}//g' \
        -e 's/${CLIENT_DIAL}//g' -e 's/${GAP_MS}/0/g' "$OUT/$side/deploy/base/$t" > "$OUT/renders/job-$t.$side.yaml"
  done
  if cmp -s "$OUT/renders/job-$t.parent.yaml" "$OUT/renders/job-$t.tree.yaml"; then
    printf 'template  %-50s IDENTICAL\n' "$t" >> "$OUT/summary.txt"
  else
    printf 'template  %-50s DIFFERS\n' "$t" >> "$OUT/summary.txt"
  fi
done
printf '\nfiles that differ between parent and tree under deploy/ and experiments/*.sh:\n' >> "$OUT/summary.txt"
diff -rq "$OUT/parent/deploy" "$OUT/tree/deploy" | sed "s#$OUT/##g" >> "$OUT/summary.txt" || true
for f in "$OUT"/tree/experiments/*.sh; do b=$(basename "$f"); cmp -s "$f" "$OUT/parent/experiments/$b" || echo "experiments/$b differs" >> "$OUT/summary.txt"; done
printf 'placeholders left in any render, outside comments: %s\n' "$(cat "$OUT"/renders/*.yaml | grep -v '^[[:space:]]*#' | grep -c '\${' || true)" >> "$OUT/summary.txt"
