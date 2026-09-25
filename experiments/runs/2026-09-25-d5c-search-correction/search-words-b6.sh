#!/usr/bin/env bash
# search-words-b6.sh -- D-5c: B-6's tracker search (experiments/runs/2026-09-23-b6-traces-and-table/tracker-search.sh and
# .txt, kept as written) re-run as WORD searches. B-6's script passed each query to gh search issues --include-prs as one
# argument after --; gh 2.101.0 sends an argument holding a space as a quoted phrase (gh-phrase-check.txt), so its
# sixteen multi-word queries' pages matched the exact phrase only, while the total_count beside each came from gh api,
# a word search. Its ten single-token queries (event-stream, ParseDataStream, non-SSE, silently, SubscribeToTask,
# on_subscribe_to_task, UnsupportedOperationError twice, resubscribe, Resubscribe) went out unquoted and are not
# re-run. Scope: the sixteen multi-word queries, each on its repository as is:issue and as is:pr, title, body and
# comments matched.
here="$(cd "$(dirname "$0")" && pwd)"; source "$here/words-lib.sh"
out="${1:?usage: search-words-b6.sh <out-file> <jsonl-file>}"; jsonl="${2:?}"; tag=b6
head_lines
echo "# D-5c / B-6: sixteen multi-word queries as words, issues and pull requests separately." >> "$out"
for t in "content-type streaming" "application/json response streaming" "SSE parse" "empty stream" \
         "streaming error not reported" "client ignores error" "JSON-RPC error stream" "SubscribeToTask error" \
         "sendStreamingMessage error" "content type check"; do
  both a2aproject/a2a-go $t
done
for t in "terminal state" "already completed" "InvalidParams terminal"; do
  both a2aproject/a2a-python $t
done
for t in "terminal state" "SubscribeToTask terminal" "no active execution"; do
  both a2aproject/a2a-go $t
done
tail_line
