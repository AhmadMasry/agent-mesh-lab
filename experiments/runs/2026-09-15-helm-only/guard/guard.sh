#!/usr/bin/env bash
# Follow-ups 11: the helm-required guard, demonstrated with a PATH that lacks helm. `make -n` runs no recipe line,
# and the reduced PATH holds neither kubectl nor helm, so nothing here can reach the cluster; the Helm releases
# and the lab objects are read before and after with the normal PATH anyway, so the record shows it.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
OUT="$1"
REDUCED=/usr/bin:/bin:/usr/sbin:/sbin
snap() { { helm list -A -o json | jq -c '[.[] | {name, namespace, revision, updated}]'; kubectl get deploy,ds,pods -A -o json | jq -c '[.items[] | {k: .kind, ns: .metadata.namespace, n: .metadata.name, uid: .metadata.uid, gen: .metadata.generation}] | sort_by(.k, .ns, .n)'; } | shasum -a 256 | cut -d' ' -f1; }
{
echo "# helm-required with a PATH that lacks helm. $(date -u +%Y-%m-%dT%H:%M:%SZ), at HEAD $(git rev-parse HEAD)."
echo "# Makefile blob $(git rev-parse HEAD:Makefile)."
echo
echo "## the normal PATH, for comparison"
echo "\$ command -v helm -> $(command -v helm)"
echo
echo "## cluster snapshot before (sha256 of helm list -A and every Deployment, DaemonSet and Pod with its uid and generation)"
B=$(snap); echo "   $B"
echo
echo "## the demonstration"
echo "\$ env PATH=$REDUCED sh -c 'command -v helm; echo \"command -v helm exit=\$?\"; command -v make git kubectl; /usr/bin/make -n step-2; echo \"make -n step-2 exit=\$?\"'"
env PATH=$REDUCED sh -c 'command -v helm; echo "command -v helm exit=$?"; command -v make git kubectl; /usr/bin/make -n step-2; echo "make -n step-2 exit=$?"' 2>&1
echo
echo "## cluster snapshot after"
A=$(snap); echo "   $A"
echo "   before and after: $([ "$A" = "$B" ] && echo identical || echo DIFFERENT)"
} > "$OUT" 2>&1
cat "$OUT"
