#!/usr/bin/env bash
# D-2 code proof: the render proof for the manifest commit. Every kustomization under deploy/ rendered with kubectl
# kustomize (--load-restrictor=LoadRestrictionsNone, as the Makefile renders the retry sets) and the Job templates
# rendered with every placeholder any script substitutes, at the parent and at the commit, both taken by git archive;
# compared file by file; then, in the commit's renders: every HTTPRoute object compared with the parent's, every
# Service port's appProtocol, every GRPCRoute, and the new settings per Deployment and Job.
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
echo "# renders: $n; renders only in the tree: $(comm -13 <(cd "$S/parent" && ls *.out) <(cd "$S/tree" && ls *.out) | tr '\n' ' ')"
echo "# placeholders left outside a comment in the tree's renders: $(cat "$S"/tree/deploy_*.out | grep -v '^ *#' | grep -c '\${' || true)"
for side in parent tree; do
	for f in "$S/$side"/*.out; do yq ea -o=json -I=0 '[.]' "$f" > "${f%.out}.json" 2>/dev/null || echo "YQ FAILED $f"; done
done
python3 - "$S" <<'PY'
import json, os, sys
S = sys.argv[1]
def docs(side, name):
    try:
        return [d for d in json.load(open(os.path.join(S, side, name + ".json"))) if isinstance(d, dict)]
    except FileNotFoundError:
        return []
names = sorted(f[:-5] for f in os.listdir(os.path.join(S, "tree")) if f.endswith(".json"))
key = lambda d: (d.get("metadata", {}).get("namespace", ""), d.get("metadata", {}).get("name", ""))
print("# HTTPRoute objects, parent vs tree, per render (compared as parsed objects):")
for n in names:
    a = sorted((json.dumps(d, sort_keys=True) for d in docs("parent", n) if d.get("kind") == "HTTPRoute"))
    b = sorted((json.dumps(d, sort_keys=True) for d in docs("tree", n) if d.get("kind") == "HTTPRoute"))
    if a or b:
        print(f"  {n}: {len(a)} and {len(b)} HTTPRoutes, {'identical' if a == b else 'DIFFER'}")
print("# every object that is in both renders and differs, per render (kind namespace/name):")
for n in names:
    pa = {(d.get("kind"),) + key(d): d for d in docs("parent", n)}
    tb = {(d.get("kind"),) + key(d): d for d in docs("tree", n)}
    changed = [k for k in pa if k in tb and pa[k] != tb[k]]
    added = [k for k in tb if k not in pa]
    removed = [k for k in pa if k not in tb]
    if changed or added or removed:
        print(f"  {n}: changed {[' '.join(k) for k in sorted(changed)]} added {[' '.join(k) for k in sorted(added)]} removed {[' '.join(k) for k in sorted(removed)]}")
print("# Service ports in the tree renders that hold the agents' Services (render: service port name appProtocol):")
for n in names:
    for d in docs("tree", n):
        if d.get("kind") == "Service" and d["metadata"]["name"] in ("worker", "orchestrator"):
            for p in d["spec"]["ports"]:
                print(f"  {n}: {d['metadata']['name']} {p['port']} {p.get('name')} appProtocol={p.get('appProtocol', '(none)')}")
print("# every appProtocol value in any tree render, with its count:")
vals = {}
for n in names:
    for d in docs("tree", n):
        if d.get("kind") == "Service":
            for p in d.get("spec", {}).get("ports", []):
                if "appProtocol" in p:
                    vals[p["appProtocol"]] = vals.get(p["appProtocol"], 0) + 1
print("  ", vals, "; values naming a2a:", [v for v in vals if "a2a" in v])
print("# GRPCRoutes in the tree's renders:")
for n in names:
    for d in docs("tree", n):
        if d.get("kind") == "GRPCRoute":
            r = d["spec"]["rules"][0]
            pr = d["spec"]["parentRefs"][0]
            print(f"  {n}: {key(d)[0]}/{key(d)[1]} hosts={d['spec']['hostnames']} parent={pr.get('namespace')}/{pr['name']} "
                  f"backend={r['backendRefs'][0]['name']}:{r['backendRefs'][0]['port']} matches={len(r.get('matches', []))}")
full = docs("tree", "deploy_step-3-stress")
h = sorted({x for d in full if d.get("kind") == "HTTPRoute" for x in d["spec"].get("hostnames", [])})
g = sorted({x for d in full if d.get("kind") == "GRPCRoute" for x in d["spec"].get("hostnames", [])})
print(f"# hostnames in step-3's render: HTTPRoute {h}; GRPCRoute {g}; intersection {sorted(set(h) & set(g))}")
print("# the agents' settings per Deployment, in each tree render that holds them:")
wanted = ("PUBLIC_URL", "PUBLIC_GRPC_URL", "GRPC_PORT", "GRPC_LISTEN_ADDR", "REFUSE_OPERATION", "LEDGER_HEADERS", "FORWARD_RESUBSCRIBE")
for n in names:
    for d in docs("tree", n):
        if d.get("kind") == "Deployment" and d["metadata"]["name"] in ("worker", "orchestrator"):
            c = d["spec"]["template"]["spec"]["containers"][0]
            env = " ".join(f"{e['name']}={e.get('value')!r}" for e in c.get("env", []) if e["name"] in wanted)
            ports = ",".join(f"{p['name']}:{p['containerPort']}" for p in c.get("ports", []))
            print(f"  {n}: {d['metadata']['name']}: {env} ports={ports}")
print("# the Job templates' new settings, as rendered:")
for j in ("job_loadgen-job", "job_loadgen-a2-job"):
    for d in docs("tree", j):
        env = [e for e in d["spec"]["template"]["spec"]["containers"][0]["env"] if e["name"] in ("CLIENT_BINDING", "CLIENT_GRPC_AUTHORITY")]
        print(f"  {j}: {env}")
PY
echo "# files under deploy/ that differ: $(git diff --name-only "$P" "$C" -- deploy | tr '\n' ' ')"
echo "# scripts under experiments/ (not runs/) that differ: $(git diff --name-only "$P" "$C" -- experiments ':!experiments/runs' | wc -l | tr -d ' ')"
