#!/usr/bin/env bash
# search-words-b5a.sh -- D-5c: B-5a's tracker search (experiments/runs/2026-09-22-b5a-removal/tracker-search.txt, kept as
# written) re-run as WORD searches. B-5a's two takes ran gh search issues (take 2 with --include-prs) with --match
# title,body and one query argument each; gh 2.101.0 sends an argument holding a space as a quoted phrase
# (gh-phrase-check.txt), so its seven multi-word queries matched the exact phrase only. Its end table of gh api
# total_count was a word search, and its note put the gap down to comment matching; the phrase is the larger part of it.
# The seven single-token queries (drain, shutdown, SIGTERM, terminationMinDeadline, CONNECTION_MIN_TERMINATION_DEADLINE,
# shutdown.min, 55s) went out unquoted and are not re-run. Scope: the seven multi-word queries on agentgateway/
# agentgateway, each as is:issue and as is:pr, title, body and comments matched.
here="$(cd "$(dirname "$0")" && pwd)"; source "$here/words-lib.sh"
out="${1:?usage: search-words-b5a.sh <out-file> <jsonl-file>}"; jsonl="${2:?}"; tag=b5a
head_lines
echo "# D-5c / B-5a: seven multi-word queries as words, issues and pull requests separately." >> "$out"
for t in "graceful shutdown" "termination deadline" "minimum drain" "drain timeout" "in-flight connections" \
         "long-lived connections" "SSE stream cut"; do
  both agentgateway/agentgateway $t
done
tail_line
