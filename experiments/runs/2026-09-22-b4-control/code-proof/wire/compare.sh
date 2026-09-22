#!/usr/bin/env bash
# Masks the per-run values (UUIDs, ports, the line's ts) and compares every run to parent-unset.
set -uo pipefail
W="${TMPDIR%/}/b4/wire"
mask() { perl -pe 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g; s/127\.0\.0\.1:\d+/127.0.0.1:<port>/g; s/"ts":"[^"]*"/"ts":"<ts>"/g' "$1"; }
for run in parent-unset parent-rendered committed-unset committed-rendered committed-host; do
	for f in req-1.bin req-2.bin stdout stderr exit; do mask "$W/$run/$f" > "$W/$run/$f.masked"; done
	printf '%-16s GET %4s bytes sha256 %s | POST %4s bytes sha256 %s | line sha256 %s | stderr %s bytes | %s\n' "$run" \
		"$(wc -c < "$W/$run/req-1.bin" | tr -d ' ')" "$(shasum -a 256 < "$W/$run/req-1.bin.masked" | cut -c1-16)" \
		"$(wc -c < "$W/$run/req-2.bin" | tr -d ' ')" "$(shasum -a 256 < "$W/$run/req-2.bin.masked" | cut -c1-16)" \
		"$(shasum -a 256 < "$W/$run/stdout.masked" | cut -c1-16)" "$(wc -c < "$W/$run/stderr" | tr -d ' ')" "$(cat "$W/$run/exit")"
done
for run in parent-rendered committed-unset committed-rendered; do
	for f in req-1.bin req-2.bin stdout stderr exit; do
		if cmp -s "$W/parent-unset/$f.masked" "$W/$run/$f.masked"; then r=equal; else r=DIFFERS; fi
		echo "parent-unset vs $run: $f (masked) $r"
	done
done
echo
echo "== committed-host (CLIENT_HOST=worker.lab.internal) against committed-unset, masked, every differing line:"
for f in req-1.bin req-2.bin stdout; do
	echo "-- $f"; diff "$W/committed-unset/$f.masked" "$W/committed-host/$f.masked" | tr -d '\r'
done
