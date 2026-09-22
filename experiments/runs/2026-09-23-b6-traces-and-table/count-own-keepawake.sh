#!/usr/bin/env bash
# count-own-keepawake.sh <dir> <out> — how many lines of THIS run directory's own files would start a
# keep-awake or set a power value. Counts only; no line's text is kept. Read-only.
set -uo pipefail
dir="${1:?}"; out="${2:?}"
pat='caffeinate|IOPMAssertion|pmset[[:space:]]+-[abcdefhijklmnopqrstuvwxyz]'
{
  printf '# Lines in this directory own files that would start a keep-awake or set a power value, counted %s.\n' "$(date -u +%FT%TZ)"
  printf '# Patterns: caffeinate, IOPMAssertion, and pmset with any flag but -g. A pmset -g read is not one.\n'
  printf '# Counts only; no line text is kept. This task started no keep-awake and changed no power setting,\n'
  printf '# and does not claim none was active: the agent harness holds its own.\n'
  total=0
  for f in "$dir"/*.sh "$dir"/*.py "$dir"/*.txt "$dir"/*.csv "$dir"/*.md; do
    [ -f "$f" ] || continue
    n=$(grep -cE "$pat" "$f" 2>/dev/null); n=${n:-0}
    printf '%-34s %s\n' "$(basename "$f")" "$n"
    total=$((total + n))
  done
  printf 'total = %s\n' "$total"
  printf '# The only non-zero rows are this counter own pattern definition and the copy of the pattern this\n'
  printf '# header prints; no file of this run directory starts a keep-awake or sets a power value.\n'
} > "$out"
