#!/usr/bin/env bash
# items-read.sh <out-file> — every tracker item B-6 read by NUMBER, from the API rather
# than from a search page: state, whether a pull request was MERGED or closed unmerged,
# the dates, the comment count, and for a merged pull request which release first
# contains its merge commit. Read-only.
#
# B-5a's lesson is the reason this file exists: a search page says "closed", which is
# true of a merged pull request and of a rejected one alike, and the two mean opposite
# things upstream.
set -uo pipefail
out="${1:?usage: items-read.sh <out-file>}"
: > "$out"

item() {  # item <repo> <number> <why it was read>
  local repo="$1" n="$2"; shift 2
  local why="$*"
  local j
  j="$(gh api "repos/$repo/issues/$n" 2>/dev/null)" || { printf '#%s %s: READ FAILED\n' "$n" "$repo" >> "$out"; return; }
  local title state created updated comments ispr
  title="$(printf '%s' "$j" | jq -r .title)"
  state="$(printf '%s' "$j" | jq -r .state)"
  created="$(printf '%s' "$j" | jq -r .created_at)"
  updated="$(printf '%s' "$j" | jq -r .updated_at)"
  comments="$(printf '%s' "$j" | jq -r .comments)"
  ispr="$(printf '%s' "$j" | jq -r 'if .pull_request then "pr" else "issue" end')"
  {
    printf '\n-- %s #%s [%s] %s\n' "$repo" "$n" "$ispr" "$title"
    printf '   why read: %s\n' "$why"
    printf '   state=%s created=%s updated=%s comments=%s   (read %s)\n' \
      "$state" "$created" "$updated" "$comments" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$out"
  if [ "$ispr" = pr ]; then
    local p merged mergedat sha
    p="$(gh api "repos/$repo/pulls/$n" 2>/dev/null)"
    merged="$(printf '%s' "$p" | jq -r .merged)"
    mergedat="$(printf '%s' "$p" | jq -r .merged_at)"
    sha="$(printf '%s' "$p" | jq -r .merge_commit_sha)"
    printf '   MERGED=%s merged_at=%s merge_commit=%s\n' "$merged" "$mergedat" "${sha:0:12}" >> "$out"
    if [ "$merged" = true ] && [ -n "$sha" ] && [ "$sha" != null ]; then
      local tags first="(none found)"
      tags="$(gh api "repos/$repo/releases?per_page=100" --jq '.[] | "\(.tag_name)\t\(.published_at)\t\(.prerelease)"' 2>/dev/null \
              | sort -t'	' -k2,2)"
      while IFS=$'\t' read -r tag pub pre; do
        [ -n "$tag" ] || continue
        # Two things matter here. `< /dev/null`: gh would otherwise eat the rest of this
        # loop's input. And the status is captured rather than piped into grep, because
        # under `pipefail` a `grep -q` that matches early kills gh with SIGPIPE and the
        # pipeline then reports 141, so every release reads as "does not contain".
        local st
        st="$(gh api "repos/$repo/compare/$tag...$sha" --jq '.status' < /dev/null 2>/dev/null)"
        if [ "$st" = behind ] || [ "$st" = identical ]; then
          first="$tag (published $pub, prerelease=$pre)"; break
        fi
      done <<< "$tags"
      printf '   first release whose tree contains the merge commit: %s\n' "$first" >> "$out"
    fi
  fi
  # tr -d '\r': GitHub issue bodies come back with CRLF, and a committed record here is LF.
  printf '%s' "$j" | jq -r '.body // ""' | tr -d '\r' | head -12 | sed 's/^/   | /' >> "$out"
}

{
  echo "# B-6: every tracker item read by number from the API. Read-only."
  echo "# A search page's \"closed\" does not say whether a pull request was merged; that is read here."
} >> "$out"

# --- the new draft's candidate: the nearest things upstream to a client that reads a
#     non-SSE answer to a streaming method as an empty stream
item a2aproject/a2a-go 435 "the nearest analogue the search found: a streaming client stopping on a payload it does not understand"
item a2aproject/a2a-go 385 "a JSON-RPC client decode failure that MASKS the real error -- adjacent, and its fix shows the project's posture"
item a2aproject/a2a-go 386 "the fix for #385"
item a2aproject/a2a-go 318 "the REST binding's analogue: streaming error events not deserialised into typed errors"
item a2aproject/a2a-go 319 "the fix for #318"
item a2aproject/a2a-go 332 "the only Content-Type item the search returned for the JSON-RPC path"
item a2aproject/a2a-go 162 "the one ParseDataStream leniency item, the SSE reader's own tolerance rules"
item a2aproject/a2a-go 188 "the fix for #162"

# --- the two drafts this step refreshes
item a2aproject/a2a-go 438 "the a2a-go terminal-task draft's target issue"
item a2aproject/a2a-go 439 "the sibling issue on the same code path, named in the a2a-go draft's search"
item a2aproject/a2a-python 1205 "the a2a-python terminal-task draft's target issue"
item a2aproject/a2a-python 1207 "the open PR that Fixes #1205"
item a2aproject/a2a-python 1191 "new since 2026-09-22 in the search: terminal state published to subscriber streams"
item a2aproject/a2a-python 1175 "the issue #1191 fixes"
