#!/usr/bin/env bash
# Render every kustomize overlay under deploy/ at two trees and compare object by object.
# usage: render-proof.sh <before-tree-dir> <after-tree-dir>
set -euo pipefail
B=$1; A=$2
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for k in $(cd "$A" && find deploy -name kustomization.yaml -exec dirname {} \; | sort); do
  for side in B A; do
    d=${!side}
    if [ -f "$d/$k/kustomization.yaml" ]; then kubectl kustomize "$d/$k" > "$T/$side.yaml" 2>/dev/null || echo RENDER-FAILED > "$T/$side.yaml"; else : > "$T/$side.yaml"; fi
  done
  python3 - "$k" "$T/B.yaml" "$T/A.yaml" <<'PY'
import sys,re
k,b,a=sys.argv[1:]
def objs(p):
    t=open(p).read()
    out={}
    for doc in re.split(r'(?m)^---\n',t):
        if not doc.strip(): continue
        kind=re.search(r'(?m)^kind: (.*)$',doc); name=re.search(r'(?m)^  name: (.*)$',doc); ns=re.search(r'(?m)^  namespace: (.*)$',doc)
        key=f"{kind.group(1) if kind else '?'}/{ns.group(1) if ns else ''}/{name.group(1) if name else '?'}"
        out[key]=doc
    return out
B,A=objs(b),objs(a)
same=sum(1 for x in B if x in A and B[x]==A[x])
changed=[x for x in B if x in A and B[x]!=A[x]]
removed=[x for x in B if x not in A]
added=[x for x in A if x not in B]
print(f"{k}: objects before={len(B)} after={len(A)} byte-identical={same} changed={len(changed)} removed={len(removed)} added={len(added)} {' '.join(added)}")
for x in changed+removed: print(f"  NOT IDENTICAL: {x}")
PY
done
