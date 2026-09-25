#!/usr/bin/env bash
# search-words-c9.sh -- D-5c: C-9's tracker search (experiments/runs/2026-09-24-c9-a2a-marking/tracker-search.sh and
# .txt, kept as written) re-run as WORD searches. C-9's script is B-6's shape: one argument after -- to gh search issues
# --include-prs, which gh 2.101.0 sends as a quoted phrase when it holds a space (gh-phrase-check.txt), beside a gh api
# total_count that is a word search. Its eleven multi-word queries are re-run; the four single-token queries
# (supportedInterfaces, agent-card.json, x-forwarded-proto, apply_forwarded_scheme) went out unquoted and are not.
# Scope: the eleven multi-word queries on agentgateway/agentgateway, each as is:issue and as is:pr, title, body and
# comments matched.
here="$(cd "$(dirname "$0")" && pwd)"; source "$here/words-lib.sh"
out="${1:?usage: search-words-c9.sh <out-file> <jsonl-file>}"; jsonl="${2:?}"; tag=c9
head_lines
echo "# D-5c / C-9: eleven multi-word queries as words, issues and pull requests separately." >> "$out"
for t in "agent card" "agent card url" "agent card https" "a2a https" "a2a scheme" "a2a rewrite" "forwarded scheme" \
         "a2a waypoint" "a2a appProtocol" "a2a url rewrite" "a2a card"; do
  both agentgateway/agentgateway $t
done
tail_line
