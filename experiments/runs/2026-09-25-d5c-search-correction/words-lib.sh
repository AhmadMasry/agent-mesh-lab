#!/usr/bin/env bash
# words-lib.sh -- sourced by the four search-words-*.sh scripts of D-5c, 2026-09-25. Read-only; nothing is written to
# any tracker. Modelled on experiments/runs/2026-09-25-d5-a2a-backend/tracker-search-words.sh.
#
# Every query goes out as WORDS: gh api search/issues with an explicit q= of repo:<repo>, is:issue or is:pr, and the
# words separated by spaces, per_page 100. gh api sends a field as written and adds no quotes (gh search, by contrast,
# wraps any argument holding a space in double quotes: GH_DEBUG=api in gh-phrase-check.txt). The REST default applies:
# title, body and comments are matched. A page of 100 is followed by the next page until total_count is covered.
# The search rate limit is read before every call (gh api rate_limit costs no search quota) and the script waits for
# the window; a call that errors, is throttled, or answers incomplete_results true is recorded as FAILED with its
# reason, never as 0, and is sent again once after the window resets (the retry is recorded as its own block).
set -uo pipefail
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
# one_page <tag> <query> <page>; prints ok, more or failed on stdout
one_page() {
  local tag="$1" query="$2" page="$3" body rc stamp total n
  wait_quota
  stamp="$(date -u +%FT%TZ)"
  body="$(gh api -X GET search/issues -f q="$query" -f per_page=100 -f page="$page" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$body" | jq -e '.total_count' >/dev/null 2>&1; then
    printf '== %s  q=%s  page %s\n   FAILED (rc=%d): %s\n' "$stamp" "$query" "$page" "$rc" "$(printf '%s' "$body" | head -c 200 | tr '\n' ' ')" >> "$out"
    echo failed; return
  fi
  total="$(printf '%s' "$body" | jq -r .total_count)"
  if [ "$(printf '%s' "$body" | jq -r '.incomplete_results')" = true ]; then
    printf '== %s  q=%s  page %s\n   FAILED: incomplete_results true (total_count %s)\n' "$stamp" "$query" "$page" "$total" >> "$out"
    echo failed; return
  fi
  n="$(printf '%s' "$body" | jq -r '.items | length')"
  printf '== %s  q=%s  page %s   total_count=%s, incomplete_results=false, on the page %s\n' "$stamp" "$query" "$page" "$total" "$n" >> "$out"
  printf '%s' "$body" | jq -r '.items[] | "     #\(.number) [\(.state)\(if .pull_request.merged_at then " merged" else "" end)]\(if .pull_request then " PR" else "" end) \(.title)"' >> "$out"
  printf '%s' "$body" | jq -c --arg tag "$tag" --arg q "$query" --argjson page "$page" \
    '.items[] | {tag:$tag, q:$q, page:$page, repo:(.repository_url|split("/")|.[-2:]|join("/")), number, state, pr:(.pull_request!=null), merged:(.pull_request.merged_at!=null), title}' >> "$jsonl"
  if [ $(( page * 100 )) -lt "$total" ]; then echo more; else echo ok; fi
}
# q <repo> <is:issue|is:pr> <words...>
q() {
  local repo="$1" kind="$2"; shift 2
  local query="repo:$repo $kind $*" page=1 r
  while :; do
    r="$(one_page "$tag" "$query" "$page")"
    if [ "$r" = failed ]; then
      printf '   (re-running the failed call after the window resets)\n' >> "$out"
      local reset now w; reset="$(gh api rate_limit --jq '.resources.search.reset' 2>/dev/null || echo 0)"
      now="$(date -u +%s)"; w=$(( reset - now + 2 )); [ "$w" -lt 1 ] && w=5; [ "$w" -gt 90 ] && w=90; sleep "$w"
      r="$(one_page "$tag" "$query" "$page")"
      [ "$r" = failed ] && { printf '   FAILED twice; recorded as FAILED, not as 0\n' >> "$out"; return; }
    fi
    [ "$r" = more ] || return 0
    page=$(( page + 1 ))
  done
}
both() { local repo="$1"; shift; q "$repo" is:issue "$@"; q "$repo" is:pr "$@"; }
head_lines() {
  : > "$out"; : > "$jsonl"
  printf '# gh %s; gh api rate_limit at the start: search %s\n' "$(gh --version | head -1 | awk '{print $3}')" \
    "$(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')" >> "$out"
}
tail_line() { echo "# done $(date -u +%FT%TZ); search $(gh api rate_limit --jq '.resources.search | "\(.remaining)/\(.limit)"')" >> "$out"; }
