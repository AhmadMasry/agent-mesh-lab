#!/usr/bin/env bash
# Follow-ups 12: the parse-time Helm check, demonstrated with two PATHs that lack helm, against the base commit's
# Makefile and the Makefile commit 1 carries.
#
#   experiments/runs/2026-09-15-ingress-namespace/guard/guard.sh <base-commit> <output-file>
#
# PATH "reduced" is /usr/bin:/bin:/usr/sbin:/sbin, the one followups-11 recorded. PATH "all-but-helm" is this
# host's PATH with every directory that holds a helm replaced by a scratch directory of symlinks to everything in
# it except helm, so kubectl, go, ko, kind and docker still resolve -- the reviewer's reproduction of M2. Every
# make call is `make -n`, which runs no recipe line; the cluster is read before and after with the normal PATH
# anyway, so the record shows nothing changed. The base Makefile is `git show <base>:Makefile`, run with `make -f`
# from the repository root so every relative path in it resolves as it does for the real file. The scratch directory's
# path is written as <tmp>.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
BASE="$1"; OUT="$2"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git show "$BASE:Makefile" > "$TMP/Makefile.base"
REDUCED=/usr/bin:/bin:/usr/sbin:/sbin
FARM_PATH=""
IFS=: read -r -a dirs <<< "$PATH"
n=0
for d in "${dirs[@]}"; do
	if [ -x "$d/helm" ]; then
		n=$((n+1)); farm="$TMP/farm$n"; mkdir -p "$farm"
		for f in "$d"/*; do [ "$(basename "$f")" = helm ] || ln -s "$f" "$farm/$(basename "$f")"; done
		d="$farm"
	fi
	FARM_PATH="${FARM_PATH:+$FARM_PATH:}$d"
done
snap() { { helm list -A -o json | jq -c '[.[] | {name, namespace, revision, updated}]'; kubectl get deploy,ds,pods -A -o json | jq -c '[.items[] | {k: .kind, ns: .metadata.namespace, n: .metadata.name, uid: .metadata.uid, gen: .metadata.generation}] | sort_by(.k, .ns, .n)'; } | shasum -a 256 | cut -d' ' -f1; }
run() { # label, path, makefile, goals...
	local label="$1" p="$2" mf="$3"; shift 3
	echo "### $label: env PATH=<$([ "$p" = "$REDUCED" ] && echo reduced || echo all-but-helm)> make -f $mf -n $*"
	env PATH="$p" sh -c 'make -f "$0" -n "$@"; echo "exit=$?"' "$mf" "$@" 2>&1 | sed 's/^/   /'
	echo
}
{
echo "# The Helm check with a PATH that lacks helm, $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "# base Makefile:     $BASE:Makefile blob $(git rev-parse "$BASE:Makefile")"
echo "# commit 1 Makefile: working tree Makefile blob $(git hash-object Makefile) (check with git rev-parse <commit>:Makefile)"
echo "# host make: $(command -v make), $(make --version | head -1)"
echo
echo "## the two PATHs"
echo "   normal:        command -v helm -> $(command -v helm)"
echo "   reduced:       $REDUCED; command -v helm -> $(env PATH=$REDUCED sh -c 'command -v helm || echo "(none, exit $?)"'); kubectl -> $(env PATH=$REDUCED sh -c 'command -v kubectl || echo "(none)"')"
echo "   all-but-helm:  $n PATH director$([ $n = 1 ] && echo y || echo ies) holding helm replaced by symlink farms; command -v helm -> $(env PATH="$FARM_PATH" sh -c 'command -v helm || echo "(none, exit $?)"'); kubectl -> $(env PATH="$FARM_PATH" sh -c 'command -v kubectl')"
echo
echo "## cluster snapshot before (sha256 of helm list -A and every Deployment, DaemonSet and Pod with uid and generation)"
B=$(snap); echo "   $B"
echo
echo "## base commit's Makefile: the recipe check only"
run "base" "$FARM_PATH" "$TMP/Makefile.base" step-1 step-2
run "base" "$REDUCED" "$TMP/Makefile.base" step-1 step-2
echo "## commit 1's Makefile: the check while make reads the file"
run "commit-1" "$FARM_PATH" Makefile step-1 step-2
run "commit-1" "$REDUCED" Makefile step-1 step-2
run "commit-1" "$FARM_PATH" Makefile cluster-kind step-2b
run "commit-1" "$FARM_PATH" Makefile step-3
echo "## control: a command line naming no Helm goal is not stopped"
run "commit-1" "$FARM_PATH" Makefile step-1
echo "## cluster snapshot after"
A=$(snap); echo "   $A"
echo "   before and after: $([ "$A" = "$B" ] && echo identical || echo DIFFERENT)"
} 2>&1 | sed "s#$TMP#<tmp>#g" > "$OUT"
cat "$OUT"
