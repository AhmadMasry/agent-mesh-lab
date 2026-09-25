#!/usr/bin/env bash
# search-words-b3.sh -- D-5c: B-3's tracker search (experiments/runs/2026-09-21-b3-streaming-client/tracker-search.txt,
# kept as written) re-run as WORD searches. B-3 committed no script; its record names gh search issues and gh search prs
# and writes every query in double quotes, single words included, so the quotes are the record's notation, not a phrase
# chosen on purpose. gh 2.101.0 sends a query argument that holds a space as a quoted phrase (gh-phrase-check.txt), so
# B-3's seventeen multi-word queries matched the exact phrase only; its single-word queries (ParseDataStream, silently,
# UnsupportedOperationError) went out as words already and are not re-run. Scope: the seventeen multi-word queries (nine on a2a-go, eight on a2a-python), each
# as is:issue and as is:pr on its repository, whatever B-3 ran (issues, or pull requests for the two a2a-python "PRs"
# lines), title, body and comments matched. Two of them are fragments of error text (no active execution, is in
# terminal state); the word pass covers the phrase and more, so nothing the phrase found can be lost.
here="$(cd "$(dirname "$0")" && pwd)"; source "$here/words-lib.sh"
out="${1:?usage: search-words-b3.sh <out-file> <jsonl-file>}"; jsonl="${2:?}"; tag=b3
head_lines
echo "# D-5c / B-3: seventeen multi-word queries as words, issues and pull requests separately." >> "$out"
for t in "SubscribeToTask terminal" "resubscribe terminal state" "UnsupportedOperationError terminal" \
         "task not found subscribe" "no active execution" "SSE content-type json error" "streaming error not reported" \
         "event-stream content type" "non-SSE response"; do
  both a2aproject/a2a-go $t
done
for t in "subscribe terminal state" "SubscribeToTask terminal" "UnsupportedOperationError terminal" \
         "already completed subscribe" "InvalidParams terminal state" "resubscribe completed task" \
         "is in terminal state" "terminal state subscribe"; do
  both a2aproject/a2a-python $t
done
tail_line
