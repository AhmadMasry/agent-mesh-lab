#!/usr/bin/env bash
# Follow-ups 19, task 4b, step 0: preflight at the dispatched tip, no cluster change. Output: $1.
# experiments/runs/2026-09-19-worker-span-rebuild/preflight/preflight.sh with its first two lines (header and first printed line)
# changed to name task 4b; that script was experiments/runs/2026-09-19-currency-rebuild/preflight/preflight.sh with its header and first printed line
# changed to name this task, and the dispatched tip and tree printed beside HEAD; the commands are that script's.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
OUT="$1"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{
echo "# Follow-ups 19, task 4b, step 0: preflight, no cluster change. Started $(ts)."
echo "\$ git rev-parse --abbrev-ref HEAD -> $(git rev-parse --abbrev-ref HEAD)"
echo "\$ git rev-parse HEAD -> $(git rev-parse HEAD)"
echo "\$ git rev-parse HEAD^{tree} -> $(git rev-parse 'HEAD^{tree}')"
echo "\$ git log --format=%s -1 -> $(git log --format=%s -1)"
st=$(git status --short); echo "\$ git status --short -> ${st:-(empty)}"
echo "\$ git rev-parse origin/followups-19 -> $(git rev-parse origin/followups-19 2>&1)"
echo "\$ git ls-remote origin followups-19 -> $(git ls-remote origin followups-19 2>&1 | tr '\t' ' ')"
echo
echo "## $(ts) go build ./..."; go build ./... ; echo "exit=$?"
echo "## $(ts) go vet ./..."; go vet ./... ; echo "exit=$?"
echo "## $(ts) gofmt -l . (tracked go files)"; gofmt -l $(git ls-files '*.go') ; echo "exit=$? (no file listed above = clean)"
echo "## $(ts) go test ./... -count=1"; go test ./... -count=1 ; echo "exit=$?"
echo "## $(ts) make test"; make --no-print-directory test > "$OUT.make-test.txt" 2>&1; rc=$?; echo "exit=$rc"; echo "ok lines: $(grep -c '^ok\|: ok\| ok$' "$OUT.make-test.txt")"; echo "FAIL lines: $(grep -c 'FAIL' "$OUT.make-test.txt")"
echo "## $(ts) uv lock --check (agents/orchestrator)"; (cd agents/orchestrator && uv lock --check); echo "exit=$?"
echo "## $(ts) uv run --locked pytest -q (agents/orchestrator)"; (cd agents/orchestrator && uv run --locked pytest -q 2>&1 | tail -5); echo "exit=${PIPESTATUS[0]}"
st=$(git status --short); echo "## $(ts) git status --short after -> ${st:-(empty)}"
echo "# finished $(ts)"
} > "$OUT" 2>&1
