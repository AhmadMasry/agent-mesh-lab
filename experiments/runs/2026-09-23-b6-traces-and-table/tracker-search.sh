#!/usr/bin/env bash
# tracker-search.sh <out-file> — the trackers searched before B-6's one new upstream draft
# and before refreshing the two drafts that exist. Read-only: gh search / gh api. Nothing
# is written to any tracker.
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

: > "$out"
{
  echo "# B-6: the trackers searched for the one new draft this step owes (the author's decision of"
  echo "# 2026-09-22: a2a-go's client reads an application/json answer to a streaming method as an"
  echo "# empty stream) and for the two drafts it refreshes."
  echo "#"
  echo "# Tool: gh search issues --include-prs, and gh api for total_count and for each item read by"
  echo "# number. Read-only, stamps from date -u. Every query and every result is here, the empty and"
  echo "# the failed ones included. Scope and the two figures: see the header of tracker-search.sh."
  echo
  echo "############ 1. a2a-go: does anything upstream describe its CLIENT reading a non-SSE answer"
  echo "############    to a streaming method as an empty stream, with no event and no error?"
} >> "$out"
for t in "event-stream" "content-type streaming" "application/json response streaming" \
         "SSE parse" "ParseDataStream" "empty stream" "streaming error not reported" \
         "client ignores error" "non-SSE" "silently" "JSON-RPC error stream" \
         "SubscribeToTask error" "sendStreamingMessage error" "content type check"; do
  q a2aproject/a2a-go "$t"
done

{
  echo
  echo "############ 2. a2a-python: anything new on the terminal-task path since 2026-09-22?"
} >> "$out"
for t in "terminal state" "SubscribeToTask" "on_subscribe_to_task" "UnsupportedOperationError" \
         "resubscribe" "already completed" "InvalidParams terminal"; do
  q a2aproject/a2a-python "$t"
done

{
  echo
  echo "############ 3. a2a-go: anything new on the terminal-task path since 2026-09-22?"
} >> "$out"
for t in "terminal state" "SubscribeToTask terminal" "no active execution" "Resubscribe" \
         "UnsupportedOperationError"; do
  q a2aproject/a2a-go "$t"
done
echo "# end of the search blocks; every item read by number is in items-read.txt beside this file" >> "$out"
