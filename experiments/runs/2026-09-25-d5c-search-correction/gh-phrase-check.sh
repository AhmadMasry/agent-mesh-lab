#!/usr/bin/env bash
# gh-phrase-check.sh <out-file> -- D-5c: how gh search issues sends a query argument, read from GH_DEBUG=api. Only the
# request line to the search endpoint is kept. One argument with a space, one hyphenated token, one dotted token, and
# the same with --include-prs (which drops the type: qualifier). Costs one search call each.
set -uo pipefail
out="${1:?usage: gh-phrase-check.sh <out-file>}"
: > "$out"
echo "# gh $(gh --version | head -1 | awk '{print $3}'), $(date -u +%FT%TZ)" >> "$out"
chk() { # chk <label> <gh search args...>
  local label="$1"; shift
  printf '%s\n' "$(gh api rate_limit --jq '"   (rate limit: search remaining=\(.resources.search.remaining))"')" >> "$out"
  printf '%s\n  ' "$label" >> "$out"
  GH_DEBUG=api gh search issues --limit 1 --json number "$@" 2>&1 | grep -m1 '^\* Request to https://api.github.com/search' >> "$out" || true
}
chk 'gh search issues --repo agentgateway/agentgateway -- "graceful shutdown"' --repo agentgateway/agentgateway -- "graceful shutdown"
chk 'gh search issues --include-prs --repo agentgateway/agentgateway -- "agent card url"' --include-prs --repo agentgateway/agentgateway -- "agent card url"
chk 'gh search issues --include-prs --repo a2aproject/a2a-go -- "event-stream"' --include-prs --repo a2aproject/a2a-go -- "event-stream"
chk 'gh search issues --repo agentgateway/agentgateway -- "shutdown.min"' --repo agentgateway/agentgateway -- "shutdown.min"
