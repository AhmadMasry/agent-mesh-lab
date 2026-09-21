#!/usr/bin/env bash
# rec.sh <file> '<command>': appends the read stamp, the command as run, its output
# (stdout and stderr) and its exit code to <file>. Every reading in this run directory
# that is not a driver's own line was taken through this. Copied from the C-3R run
# directory (experiments/runs/2026-09-21-c3r-open-connections/rec.sh), unchanged below this header.
set -uo pipefail
f="$1"
shift
{
	printf '\n# read %s\n$ %s\n' "$(date -u +%FT%TZ)" "$*"
	bash -c "$*" 2>&1
	printf '# exit %s\n' "$?"
} >>"$f"
