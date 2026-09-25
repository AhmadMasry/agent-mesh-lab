#!/usr/bin/env bash
# followups-read.sh <out-file> -- D-5c: what items-read.txt's finds point at, read from the REST API (core quota).
# a2a-go#442's handler.go patch (the SubscribeToTask change); a2a-python#1268's comments; the releases published since
# the pins (a2a-go v2.6.0, a2a-python v1.1.5) with their dates; whether a2a-go v2.6.0 changes the two files the
# streaming-client draft cites (compare v2.5.0...v2.6.0, file list filtered to them); and #1268's diff of
# default_request_handler_v2.py and active_task.py, for whether it touches how the error is framed. Email addresses
# are replaced by <email>. Read-only.
# 2026-09-25, review round (M-3), the lines above stand as run:
# - The #1268 heading in the output says "the two source files". The filter is unanchored, so it matches four
#   patches: active_task.py, default_request_handler_v2.py, and their tests test_active_task.py and
#   test_default_request_handler_v2.py.
# - The strip regex accepts a "+" before "@". So the two diff lines "+@pytest.mark.asyncio" and
#   "+@pytest.mark.parametrize(" were replaced, and read "<email>" and "<email>('terminal_state', ...)" at
#   followups-read.txt l.148-149. They are test decorators, not addresses. No other line was changed, and no address
#   is in the fetched text.
set -uo pipefail
out="${1:?usage: followups-read.sh <out-file>}"
: > "$out"
strip() { tr -d '\r' | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'; }
echo "# D-5c follow-up reads, $(date -u +%FT%TZ); core quota $(gh api rate_limit --jq '.resources.core | "\(.remaining)/\(.limit)"')" >> "$out"
{
  echo; echo "## a2a-go#442, a2asrv/handler.go patch"
  gh api "repos/a2aproject/a2a-go/pulls/442/files" --jq '.[] | select(.filename=="a2asrv/handler.go") | .patch'
  echo; echo "## a2a-python#1268, issue comments"
  gh api "repos/a2aproject/a2a-python/issues/1268/comments" --jq '.[] | "-- \(.created_at) author_association=\(.author_association)\n\(.body)"'
  echo; echo "## a2a-python#1268, reviews"
  gh api "repos/a2aproject/a2a-python/pulls/1268/reviews" --jq '.[] | "-- \(.submitted_at) \(.state) author_association=\(.author_association)\n\(.body)"'
  echo; echo "## a2a-python#1268, patches of the two source files it changes on the v2 path"
  gh api "repos/a2aproject/a2a-python/pulls/1268/files" --jq '.[] | select(.filename|test("default_request_handler_v2.py|active_task.py")) | "### \(.filename)\n\(.patch)"'
  echo; echo "## releases, newest five of each"
  for r in a2aproject/a2a-go a2aproject/a2a-python; do
    gh api "repos/$r/releases?per_page=5" --jq ".[] | \"$r \(.tag_name) published=\(.published_at) prerelease=\(.prerelease)\""
  done
  echo; echo "## a2a-go v2.5.0...v2.6.0: status, and the two files the streaming-client draft cites"
  gh api "repos/a2aproject/a2a-go/compare/v2.5.0...v2.6.0" --jq '"status=\(.status) ahead_by=\(.ahead_by) files=\(.files|length)"'
  gh api "repos/a2aproject/a2a-go/compare/v2.5.0...v2.6.0" --jq '[.files[] | select(.filename=="a2aclient/jsonrpc.go" or .filename=="internal/sse/sse.go") | "\(.filename) \(.status) +\(.additions) -\(.deletions)"] | if length==0 then "neither a2aclient/jsonrpc.go nor internal/sse/sse.go changed" else .[] end'
  echo; echo "## a2a-go v2.6.0 release notes"
  gh api "repos/a2aproject/a2a-go/releases/tags/v2.6.0" --jq .body
} 2>&1 | strip >> "$out"
echo "# done $(date -u +%FT%TZ)" >> "$out"
