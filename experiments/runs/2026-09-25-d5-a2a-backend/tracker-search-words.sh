#!/usr/bin/env bash
# tracker-search-words.sh <out-file> -- D-5, the SECOND PASS of rule 11's search, 2026-09-25, by the controller's review
# ruling (I-1). The first pass (tracker-search.sh, kept as written) passed each query to gh search issues as one
# argument, which gh 2.101.0 sends as a quoted phrase, so its result pages matched the exact phrase only. This pass
# sends every query as WORDS: gh api search/issues with an explicit q= of the words separated, repo:agentgateway/
# agentgateway, and is:issue or is:pr, one call each, per_page 100. Beside each page, the same call's own total_count
# and incomplete_results. The search rate limit is read before every call (gh api rate_limit costs no search quota)
# and the script waits for the window; a call that errors, is throttled, or answers incomplete_results true is
# recorded as FAILED with its reason, never as 0 results. Read-only; nothing is written to any tracker.
set -uo pipefail
out="${1:?usage: tracker-search-words.sh <out-file>}"
REPO=agentgateway/agentgateway
wait_quota() {
  while :; do
    local rem reset now w
    rem="$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null || echo 0)"
    reset="$(gh api rate_limit --jq '.resources.search.reset' 2>/dev/null || echo 0)"
    printf '   (rate limit read %s: search remaining=%s)\n' "$(date -u +%FT%TZ)" "$rem" >> "$out"
    [ "${rem:-0}" -ge 2 ] && return 0
    now="$(date -u +%s)"; w=$(( reset - now + 2 )); [ "$w" -lt 1 ] && w=5; [ "$w" -gt 90 ] && w=90
    printf '   (waiting %ss for the search window to reset)\n' "$w" >> "$out"
    sleep "$w"
  done
}
q() { # q <is:issue|is:pr> <words...>
  local kind="$1"; shift
  local query="repo:$REPO $kind $*" body rc stamp
  wait_quota
  stamp="$(date -u +%FT%TZ)"
  body="$(gh api -X GET search/issues -f q="$query" -f per_page=100 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$body" | jq -e '.total_count' >/dev/null 2>&1; then
    printf '== %s  q=%s\n   FAILED (rc=%d): %s\n' "$stamp" "$query" "$rc" "$(printf '%s' "$body" | head -c 200 | tr '\n' ' ')" >> "$out"; return
  fi
  if [ "$(printf '%s' "$body" | jq -r '.incomplete_results')" = true ]; then
    printf '== %s  q=%s\n   FAILED: incomplete_results true (total_count %s)\n' "$stamp" "$query" "$(printf '%s' "$body" | jq -r .total_count)" >> "$out"; return
  fi
  printf '== %s  q=%s   total_count=%s, on the page %s\n' "$stamp" "$query" "$(printf '%s' "$body" | jq -r .total_count)" "$(printf '%s' "$body" | jq -r '.items | length')" >> "$out"
  printf '%s' "$body" | jq -r '.items[] | "     #\(.number) [\(.state)\(if .pull_request.merged_at then " merged" else "" end)]\(if .pull_request then " PR" else "" end) \(.title)"' >> "$out"
}
: > "$out"
{
  echo "# D-5 second pass: the first pass's 20 queries as word searches, issues and pull requests separately."
  echo "# gh $(gh --version | head -1 | awk '{print $3}'); gh api rate_limit at the start: search $(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')"
  echo
} >> "$out"
for t in "a2a backend" "AgentgatewayBackend a2a" "a2a static backend" "static backend hbone" "static backend mesh" \
         "static backend ambient" "backend mtls ambient" "a2a ambient" "a2a waypoint" "A2ABackend" "BuildAgwBackend" \
         "from_shared" "transport_override" "a2a service reference" "agent card invalid JSON" "agent card grpc" \
         "a2a grpc interface" "public_interface_url" "rewrite_agent_card" "supportedInterfaces grpc"; do
  q is:issue $t
  q is:pr $t
done
echo "# done $(date -u +%FT%TZ); search $(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')" >> "$out"
