#!/usr/bin/env bash
# tracker-search.sh <out-file> -- C-9: the agentgateway tracker searched before C-9 drafts an upstream text on the A2A
# agent-card rewrite advertising https for a plain-HTTP agent. Read-only: gh search / gh api. Nothing is written to any
# tracker. Adapted from experiments/runs/2026-09-23-b6-traces-and-table/tracker-search.sh: this header and the queries
# changed; the scope, the two figures, the rate-limit wait and the FAILED rule are that script's.
#
# SCOPE, stated rather than implied. `gh search issues` WITHOUT --include-prs returns
# ISSUES ONLY -- the mistake B-5a's first search made and the reason its conclusion was
# wrong -- so every query here passes it, and a block is labelled "issues and pull
# requests, any state" only because that is what it ran.
#
# Two figures per query, and they are not the same search:
#   * the PAGE this query returned under --limit 20 over title and body (a page of 20
#     means the page was full and there are more);
#   * the REST search API's own total_count for the same text, which matches title, body
#     AND comments, so it bounds the page from above rather than reproducing it.
#
# The search API allows 30 requests a minute and each query here costs two. This script
# therefore reads `gh api rate_limit` (which costs no search quota) before every call and
# waits for the window to reset rather than letting a query fail quietly: a rate-limited
# query returns an empty page that reads exactly like a genuine "no results", which is a
# way to conclude "nothing on point" and be wrong. Any call that still fails is recorded
# as FAILED with the reason, never as 0 results.
set -uo pipefail
out="${1:?usage: tracker-search.sh <out-file>}"

wait_for_search_quota() {   # keep at least 4 in the window before spending 2
  while :; do
    local rem reset now
    rem="$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null || echo 0)"
    reset="$(gh api rate_limit --jq '.resources.search.reset' 2>/dev/null || echo 0)"
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

set -uo pipefail
out="${1:?usage: tracker-search.sh <out-file>}"
wait_for_search_quota() {   # keep at least 4 in the window before spending 2
  while :; do
    local rem reset now
    rem="$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null || echo 0)"
    reset="$(gh api rate_limit --jq '.resources.search.reset' 2>/dev/null || echo 0)"
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
  echo "# C-9: does anything upstream describe agentgateway's A2A agent-card rewrite taking its scheme from the"
  echo "# downstream connection (https behind HBONE or a waypoint) or from X-Forwarded-Proto, or change the rewrite after v1.5.0?"
  echo "# Tool: gh search issues --include-prs, and gh api for total_count. Read-only, stamps from date -u."
  echo "# gh api rate_limit at the start: core $(gh api rate_limit --jq '.resources.core | "\(.remaining)/\(.limit)"'), search $(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')"
  echo
} >> "$out"
for t in "agent card" "agent card url" "agent card https" "a2a https" "a2a scheme" "supportedInterfaces" "a2a rewrite" \
         "agent-card.json" "x-forwarded-proto" "forwarded scheme" "apply_forwarded_scheme" "a2a waypoint" "a2a appProtocol" \
         "a2a url rewrite" "a2a card"; do
  q agentgateway/agentgateway "$t"
done
echo "# done $(date -u +%FT%TZ); gh api rate_limit at the end: core $(gh api rate_limit --jq '.resources.core | "\(.remaining)/\(.limit)"'), search $(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')" >> "$out"
