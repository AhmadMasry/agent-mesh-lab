#!/usr/bin/env bash
# Follow-ups 23: the built tree's deployed subtree and blob ids, beside follow-ups 22's built tree (8dd9ea9c,
# "docs(versions): pin-audit-2026-09-25 carries a dated correction, ..."). Read-only. $1 = output.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
CMP=8dd9ea9c
{
echo "# HEAD $(git rev-parse HEAD) ($(git log --format=%s -1 | cut -c1-120)...), tree $(git rev-parse 'HEAD^{tree}')"
echo "# compared with $(git rev-parse $CMP) ($(git log --format=%s -1 $CMP | cut -c1-80)...), the tree follow-ups 22 built"
printf '%-40s %-42s %-42s %s\n' path HEAD followups-22 same
for p in deploy Makefile agents fixtures internal experiments/lib .ko.yaml go.mod go.sum kind-config.yaml $(git ls-files ':(glob)experiments/*.sh'); do
	h=$(git rev-parse "HEAD:$p"); c=$(git rev-parse -q --verify "$CMP:$p" 2>/dev/null || echo absent)
	printf '%-40s %-42s %-42s %s\n' "$p" "$h" "$c" "$([ "$h" = "$c" ] && echo same || echo DIFFERS)"
done
echo "# Go-sources hash (the Makefile's GO_SOURCES_HASH command): $(git ls-files -s -- agents/worker fixtures/mockllm fixtures/extauthz internal go.mod go.sum ':!**/*_test.go' | git hash-object --stdin)"
} > "$1"
