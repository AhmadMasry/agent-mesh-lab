#!/usr/bin/env bash
# items-read.sh <out-file> -- D-5c: every item the word pass returned that no page of the original showed and whose
# title bears on a draft or entry resting on that search, read by NUMBER from the REST API (core quota, not search):
# state, state_reason, dates, comments; for a pull request, merged, merged_at, the merge commit, and its containment
# against the release the entry pinned and against the repository's latest release (compare <tag>...<sha>: behind or
# identical = contained, ahead or diverged = not contained). The body's first 30 lines, with any email address
# replaced by <email> and carriage returns dropped. Read-only.
# 2026-09-25, review round: #435, #1172 (M-4) and #1597, #1407 (M-1, the capped pass) added; the file re-run whole.
set -uo pipefail
out="${1:?usage: items-read.sh <out-file>}"
: > "$out"
echo "# D-5c: items read by number, $(date -u +%FT%TZ); core quota $(gh api rate_limit --jq '.resources.core | "\(.remaining)/\(.limit)"')" >> "$out"
strip() { tr -d '\r' | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'; }
contain() { # contain <repo> <tag> <sha>
  local s; s="$(gh api "repos/$1/compare/$2...$3" --jq '"\(.status) ahead_by=\(.ahead_by) behind_by=\(.behind_by)"' 2>/dev/null || echo 'READ FAILED')"
  case "$s" in behind*|identical*) printf '   vs %s: %s (contained)\n' "$2" "$s";; *) printf '   vs %s: %s (not contained)\n' "$2" "$s";; esac
}
item() { # item <repo> <pin tag> <number> <why>
  local repo="$1" pin="$2" n="$3"; shift 3
  local j; j="$(gh api "repos/$repo/issues/$n" 2>/dev/null)" || { printf '\n-- %s#%s READ FAILED\n' "$repo" "$n" >> "$out"; return; }
  {
    printf '\n-- %s#%s [%s] %s\n' "$repo" "$n" "$(printf '%s' "$j" | jq -r 'if .pull_request then "PR" else "issue" end')" "$(printf '%s' "$j" | jq -r .title)"
    printf '   why read: %s\n' "$*"
    printf '%s' "$j" | jq -r '"   state=\(.state) state_reason=\(.state_reason) created=\(.created_at) updated=\(.updated_at) closed=\(.closed_at) comments=\(.comments)"'
    printf '   (read %s)\n' "$(date -u +%FT%TZ)"
  } >> "$out"
  if printf '%s' "$j" | jq -e .pull_request >/dev/null; then
    local p sha latest; p="$(gh api "repos/$repo/pulls/$n")"
    sha="$(printf '%s' "$p" | jq -r .merge_commit_sha)"
    printf '%s' "$p" | jq -r '"   merged=\(.merged) merged_at=\(.merged_at) merge_commit=\(.merge_commit_sha) head=\(.head.sha[0:12]) changed_files=\(.changed_files)"' >> "$out"
    if [ "$(printf '%s' "$p" | jq -r .merged)" = true ]; then
      latest="$(gh api "repos/$repo/releases?per_page=100" --jq '[.[] | select(.draft|not)][0].tag_name')"
      { contain "$repo" "$pin" "$sha"; [ "$latest" != "$pin" ] && contain "$repo" "$latest" "$sha"; } >> "$out"
    fi
    gh api "repos/$repo/pulls/$n/files?per_page=100" --jq '.[] | "   file \(.filename) +\(.additions) -\(.deletions)"' >> "$out"
  fi
  printf '%s' "$j" | jq -r '.body // ""' | strip | head -30 | sed 's/^/   | /' >> "$out"
}
echo "## B-3 and B-6: the a2a-go drafts" >> "$out"
item a2aproject/a2a-go v2.5.0 438 "the issue the a2a-go terminal-task draft comments on; the word pass lists it closed"
item a2aproject/a2a-go v2.5.0 442 "new: fix(a2asrv) spec error codes for terminal and parked tasks (#438)"
item a2aproject/a2a-go v2.5.0 76 "new: graceful client fallback to non-streaming (the streaming-client draft)"
item a2aproject/a2a-go v2.5.0 265 "new: a2asrv jsonrpc Content-Type (the streaming-client draft)"
item a2aproject/a2a-go v2.5.0 92 "new: fix: streaming (the streaming-client draft)"
item a2aproject/a2a-go v2.5.0 435 "review round (M-4): REST streaming stops at an unknown payload, a client streaming issue at v2.5.0"
echo >> "$out"; echo "## B-3 and B-6: the a2a-python draft" >> "$out"
item a2aproject/a2a-python v1.1.4 1205 "the issue the a2a-python draft comments on, state now"
item a2aproject/a2a-python v1.1.4 1207 "its open fix, state now"
item a2aproject/a2a-python v1.1.4 1268 "new: reject terminal-task operations with UnsupportedOperationError"
item a2aproject/a2a-python v1.1.4 215 "new: raise error for tasks in terminal states"
item a2aproject/a2a-python v1.1.4 1172 "review round (M-4): owner-scopes cancel and subscribe"
echo >> "$out"; echo "## B-5a: the drain reading" >> "$out"
item agentgateway/agentgateway v1.5.0 3210 "new: pool max connection duration"
item agentgateway/agentgateway v1.5.0 3477 "new: responseIdleTimeout cuts a streaming response"
item agentgateway/agentgateway v1.5.0 3603 "new: streaming response silently dropped"
item agentgateway/agentgateway v1.5.0 1597 "review round (M-1), capped pass: maxConnectionDuration for HTTP listeners"
item agentgateway/agentgateway v1.5.0 1407 "review round (M-1), capped pass: wait for bind before becoming ready"
echo >> "$out"; echo "## C-9: the card-rewrite draft" >> "$out"
item agentgateway/agentgateway v1.5.0 993 "new to C-9 (read in D-5): tunnel_protocol on Binds for HBONE listeners"
item agentgateway/agentgateway v1.5.0 1793 "new to C-9 (read in D-5): AppProtocol on Backend"
echo "# done $(date -u +%FT%TZ); core quota $(gh api rate_limit --jq '.resources.core | "\(.remaining)/\(.limit)"')" >> "$out"
