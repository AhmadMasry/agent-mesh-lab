#!/usr/bin/env bash
# search-words-capped.sh -- D-5c, added in the review round (the controller's ruling on M-1, 2026-09-25). The
# single-token queries of B-5a, B-6 and C-9 were word searches already, but gh search ran them with --limit 20, and
# seven of those pages were full against a larger total (B-6's tracker-search.txt; B-5a's end table):
#   B-6 a2a-go: event-stream 20/75, silently 20/31;
#   B-6 a2a-python: SubscribeToTask 20/26, UnsupportedOperationError 20/22, resubscribe 20/31;
#   B-5a take 2: drain 20/33, shutdown 20/38.
# C-9's and B-3's single-token pages were not capped short. This pass sends those seven as full word searches
# through words-lib.sh: gh api search/issues with an explicit q=, is:issue and is:pr apart, per_page 100, paged until
# total_count is covered, the rate limit read before each call. Title, body and comments are matched.
here="$(cd "$(dirname "$0")" && pwd)"; source "$here/words-lib.sh"
out="${1:?usage: search-words-capped.sh <out-file> <jsonl-file>}"; jsonl="${2:?}"
head_lines
echo "# D-5c / the seven capped single-token queries as full word searches, issues and pull requests separately." >> "$out"
tag=b6
for t in event-stream silently; do both a2aproject/a2a-go "$t"; done
for t in SubscribeToTask UnsupportedOperationError resubscribe; do both a2aproject/a2a-python "$t"; done
tag=b5a
for t in drain shutdown; do both agentgateway/agentgateway "$t"; done
tail_line
