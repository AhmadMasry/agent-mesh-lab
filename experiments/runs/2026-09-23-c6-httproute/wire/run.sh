#!/usr/bin/env bash
# One run of one binary against a fresh capture server. $1 = label, $2 = binary, $3.. = env assignments.
set -uo pipefail
W="${TMPDIR%/}/c5/wire"; label="$1"; bin="$2"; shift 2
d="$W/$label"; rm -rf "$d"; mkdir -p "$d"
python3 "$W/capture.py" "$d" "$d/port" & cap=$!
for _ in $(seq 1 50); do [ -s "$d/port" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
port=$(cat "$d/port")
env -i PATH="$PATH" HOME="$HOME" TARGET_URL="http://127.0.0.1:$port" LWI=cmp-1 "$@" "$bin" > "$d/stdout" 2> "$d/stderr"; echo "exit=$?" > "$d/exit"
wait "$cap"
echo "$label port=$port $(cat "$d/exit") requests=$(ls "$d"/req-*.bin 2>/dev/null | wc -l | tr -d ' ')"
