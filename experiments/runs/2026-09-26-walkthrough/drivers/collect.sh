#!/usr/bin/env bash
# Follow-ups 24: after the walk and the proof, the record's own files, from the scratch directory into the run directory.
#   1. logs/, timings.csv, windows.csv and walk-driver.txt, copied unchanged from $WALK_SCRATCH;
#   2. every per-work-item .log the drivers wrote (the repository ignores experiments/runs/**/*.log) copied beside itself
#      as <name>-log.txt (apply.log -> apply-log.txt), the 2026-09-25 record's rule, and counted;
#   3. every JSON config dump the drivers or the walk's reads wrote (the two proxies' /config_dump, 40 to 60 KB each)
#      moved out of the record into $DUMPS, keeping its path under the run directory, and listed in
#      config-dumps-sha256.txt with its size and sha256 (the controller's ruling of 2026-09-26: dumps as extracts and
#      sha256; the extracts are the .txt readings the drivers print from each dump beside it); the standard proof's own
#      two dumps under proof/proxies/raw stay, as every proof's record has kept them;
#   4. the checks-as-run copies the standard proof's checks.sh writes, moved out the same way and listed in
#      proof/checks-as-run-sha256.txt (never committed; the 2026-09-25 record's rule).
# Reads and copies files only; nothing on the cluster. usage: WALK_SCRATCH=<dir> D=<run dir name> DUMPS=<dir> bash collect.sh
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
: "${WALK_SCRATCH:?}" "${D:?}" "${DUMPS:?}"
R="experiments/runs/$D"
mkdir -p "$R/logs" "$DUMPS"
cp "$WALK_SCRATCH"/logs/*.txt "$R/logs/"
cp "$WALK_SCRATCH/timings.csv" "$WALK_SCRATCH/windows.csv" "$R/"
[ -f "$WALK_SCRATCH/walk-driver.txt" ] && cp "$WALK_SCRATCH/walk-driver.txt" "$R/walk-driver.txt"
echo "logs copied: $(ls "$R/logs" | wc -l | tr -d ' ')"
n=0
while IFS= read -r f; do
  t="${f%.log}-log.txt"
  cp "$f" "$t"; n=$((n+1))
done < <(find "$R" -type f -name '*.log' | sort)
echo "per-work-item .log files copied beside themselves as -log.txt: $n"
# 3. the config dumps
{ echo "# path under experiments/runs/$D, bytes, sha256 -- the JSON config dumps this run's drivers and reads wrote, moved out of the record after the run ($(date -u +%FT%TZ)); each stands beside the .txt reading its driver printed from it."
  while IFS= read -r f; do
    rel="${f#$R/}"
    mkdir -p "$DUMPS/$(dirname "$rel")"
    printf '%s %s %s\n' "$rel" "$(stat -f %z "$f")" "$(shasum -a 256 "$f" | awk '{print $1}')"
    mv "$f" "$DUMPS/$rel"
  done < <(find "$R" -path "$R/proof" -prune -o -type f \( -name 'config-dump*.json' -o -name '*config-dump*.json' -o -name 'dump-*.json' -o -name '*.config_dump.json' \) -print | sort)
} > "$R/config-dumps-sha256.txt"
echo "config dumps moved out: $(($(wc -l < "$R/config-dumps-sha256.txt") - 1))"
# 4. the checks-as-run copies
if compgen -G "$R/proof/checks-as-run*" > /dev/null || find "$R" -name 'checks-as-run*.sh' | grep -q .; then
  mkdir -p "$R/proof"
  { echo "# the as-run copies of D-4's checks.sh that the proof wrote, moved out of the record ($(date -u +%FT%TZ)); path, sha256; the committed checks.sh's sha256 beside them"
    printf 'committed experiments/runs/2026-09-20-experiment-a-agentgateway-only/checks.sh %s\n' "$(shasum -a 256 experiments/runs/2026-09-20-experiment-a-agentgateway-only/checks.sh | awk '{print $1}')"
    while IFS= read -r f; do
      rel="${f#$R/}"; mkdir -p "$DUMPS/$(dirname "$rel")"
      printf '%s %s\n' "$rel" "$(shasum -a 256 "$f" | awk '{print $1}')"
      mv "$f" "$DUMPS/$rel"
    done < <(find "$R" -type f -name 'checks-as-run*.sh' | sort)
  } > "$R/proof/checks-as-run-sha256.txt"
  cat "$R/proof/checks-as-run-sha256.txt"
fi
echo "record size: $(du -sh "$R" | cut -f1); files: $(find "$R" -type f | wc -l | tr -d ' ')"
