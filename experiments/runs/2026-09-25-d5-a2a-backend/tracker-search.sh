#!/usr/bin/env bash
# tracker-search.sh <out-file> -- D-5: the agentgateway tracker searched before D-5 drafts an upstream text on the A2A
# backend type (AgentgatewayBackend spec.a2a) dialling its host in plaintext, outside the mesh, and on the agent-card
# rewrite's handling of a non-HTTP interface and of a non-JSON upstream answer. Read-only: gh search / gh api. Nothing
# is written to any tracker. C-9's tracker-search.sh, with this header and the queries changed; the scope, the two
# figures, the rate-limit wait and the FAILED rule are that script's (its function block is kept once here).
#
# SCOPE: gh search issues --include-prs, so every block is issues and pull requests, any state. Two figures per query:
# the page under --limit 20 over title and body, and the REST search API's total_count, which also matches comments.
# The rate limit is read before every call (gh api rate_limit costs no search quota) and the script waits for the
# window rather than letting a query fail quietly; a call that still fails is recorded as FAILED, never as 0 results.
# Queries are by title words AND by code function and type names.
# 2026-09-25, correction after the review (I-1), the lines above left as written: the gap between the two figures is
# NOT comments. gh 2.101.0 sends a multi-word argument after -- as a quoted phrase, so every page this script lists
# matched the exact phrase only, while total_count came from the same words unquoted. 13 of the 20 pages read 0,
# all multi-word: 12 against a total_count of 1 to 16, and 1 against 0. The word search is the second pass,
# tracker-search-words.sh, with its output tracker-search-words.txt; this file and its output are kept as they ran.
set -uo pipefail
out="${1:?usage: tracker-search.sh <out-file>}"
wait_for_search_quota() {   # keep at least 4 in the window before spending 2
  while :; do
    local rem reset now
    rem="$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null || echo 0)"
    reset="$(gh api rate_limit --jq '.resources.search.reset' 2>/dev/null || echo 0)"
    printf '   (rate limit read %s: search remaining=%s)\n' "$(date -u +%FT%TZ)" "$rem" >> "$out"
    [ "${rem:-0}" -ge 4 ] && return 0
    now="$(date -u +%s)"
    local w=$(( reset - now + 2 ))
    [ "$w" -lt 1 ] && w=5
    [ "$w" -gt 90 ] && w=90
    printf '   (waiting %ss for the search window to reset; remaining=%s)\n' "$w" "$rem" >> "$out"
    sleep "$w"
  done
}
q() {  # q <repo> <query text>
  local repo="$1"; shift
  local text="$*"
  wait_for_search_quota
  local stamp; stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local total err rows rc
  total="$(gh api -X GET search/issues -f q="repo:$repo $text" -f per_page=1 --jq '.total_count' 2>/dev/null)"
  case "$total" in ''|*[!0-9]*) total="FAILED (no total_count returned)";; esac
  err="$(mktemp)"
  rows="$(gh search issues --include-prs --repo "$repo" --limit 20 \
            --json number,state,isPullRequest,title \
            --jq '.[] | "     #\(.number) [\(.state)]\(if .isPullRequest then " PR" else "" end) \(.title)"' \
            -- "$text" 2>"$err")"
  rc=$?
  printf '== %s  issues and pull requests, any state: repo:%s %s   (API total_count, wider query: %s)\n' \
    "$stamp" "$repo" "$text" "$total" >> "$out"
  if [ "$rc" -ne 0 ]; then
    printf '   QUERY FAILED (rc=%d): %s\n' "$rc" "$(head -1 "$err")" >> "$out"
  elif [ -z "$rows" ]; then
    printf '   0 results on the page\n' >> "$out"
  else
    printf '   %d result(s) on the page:\n%s\n' "$(printf '%s\n' "$rows" | grep -c '')" "$rows" >> "$out"
  fi
  rm -f "$err"
}
: > "$out"
{
  echo "# D-5: does anything upstream describe the A2A backend type (static host and port) bypassing mesh transport,"
  echo "# a Service reference for it, the card rewrite and a gRPC interface, or the card rewrite on a non-JSON answer?"
  echo "# Tool: gh search issues --include-prs, and gh api for total_count. Read-only, stamps from date -u."
  echo "# gh api rate_limit at the start: core $(gh api rate_limit --jq '.resources.core | "\(.remaining)/\(.limit)"'), search $(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')"
  echo
} >> "$out"
for t in "a2a backend" "AgentgatewayBackend a2a" "a2a static backend" "static backend hbone" "static backend mesh" \
         "static backend ambient" "backend mtls ambient" "a2a ambient" "a2a waypoint" "A2ABackend" "BuildAgwBackend" \
         "from_shared" "transport_override" "a2a service reference" "agent card invalid JSON" "agent card grpc" \
         "a2a grpc interface" "public_interface_url" "rewrite_agent_card" "supportedInterfaces grpc"; do
  q agentgateway/agentgateway "$t"
done
echo "# done $(date -u +%FT%TZ); gh api rate_limit at the end: core $(gh api rate_limit --jq '.resources.core | "\(.remaining)/\(.limit)"'), search $(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')" >> "$out"
