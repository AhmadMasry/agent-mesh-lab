#!/usr/bin/env bash
# copy-records.sh <directory to fill> -- COPIES of every committed work item that has an
# attribution.txt, so that before-after.py reads copies and no record is opened by a tool
# that was not the one that wrote it. Run from the repository root. The list comes from
# git, so an uncommitted directory is never included. Each copy holds the five files the
# derivation reads, where the record has them, and the record's attribution.txt.
set -euo pipefail
dest="$1"
mkdir -p "$dest"
git ls-files 'experiments/runs/**/attribution.txt' | while read -r recorded; do
	src=$(dirname "$recorded")
	run=$(printf '%s\n' "$src" | cut -d/ -f3)
	copy="${dest}/${run}__$(basename "$src")"
	# Two runs can hold a work item of the same name under different sub-directories
	# (a rebuild's re-take); the path below the run keeps them apart.
	if [ -e "$copy" ]; then copy="${copy}__$(printf '%s\n' "$src" | cut -d/ -f4- | tr '/' '_')"; fi
	mkdir -p "$copy"
	for f in ingress.jsonl execution.jsonl invocation.jsonl client.jsonl spans.csv attribution.txt; do
		if [ -f "${src}/${f}" ]; then cp "${src}/${f}" "${copy}/${f}"; fi
	done
done
echo "copied $(find "$dest" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') work items"
