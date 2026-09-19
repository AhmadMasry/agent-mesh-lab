#!/usr/bin/env bash
# The ingress ledger lines the span test logged, before and after the change, compared byte for byte.
#
#   ledger-before.txt   the lines of before-final-test-on-the-parent.txt (the parent commit's code)
#   ledger-after.txt    the lines of after.txt (the tree of this change)
#
# Both are written AS THE LEDGER WROTE THEM. Only in the comparison, and only there, two values are masked, on
# every line: ts_arrival (the clock) and the port of `remote`. That port differs from run to run on the six lines
# of a real connection, where the loopback picks it; on the four lines served in process it is httptest's fixed
# 192.0.2.1:1234, which does not vary and is masked only because one pattern covers both (checked
# 2026-09-19T19:16:31Z with a mask for 127.0.0.1 alone, 1234 left as written: byte-identical too). Every id, hash,
# length, status and injection is compared as written, and so are the order of the lines and of the keys.
# It reads and writes this directory only; it touches no cluster and no checkout. Run: bash compare-ledgers.sh
set -euo pipefail
cd "$(dirname "$0")"

extract() {
  grep -E '^[[:space:]]+(span_test\.go:[0-9]+: ingress ledger, |\{"ledger":"ingress")' "$1" |
    sed -E 's/^[[:space:]]+span_test\.go:[0-9]+: /# /; s/^[[:space:]]+//'
}
mask() {
  sed -E 's/"ts_arrival":"[^"]*"/"ts_arrival":"TS"/; s/("remote":"[0-9.]+):[0-9]+"/\1:PORT"/' "$1"
}

extract before-final-test-on-the-parent.txt >ledger-before.txt
extract after.txt >ledger-after.txt

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mask ledger-before.txt >"$tmp/before"
mask ledger-after.txt >"$tmp/after"

echo "cases:  before $(grep -c '^#' ledger-before.txt), after $(grep -c '^#' ledger-after.txt)"
echo "lines:  before $(grep -c '^{' ledger-before.txt), after $(grep -c '^{' ledger-after.txt)"
echo "sha256 of the masked lines, before: $(shasum -a 256 <"$tmp/before" | cut -d' ' -f1)"
echo "sha256 of the masked lines, after:  $(shasum -a 256 <"$tmp/after" | cut -d' ' -f1)"
if cmp -s "$tmp/before" "$tmp/after"; then
  echo "RESULT: byte-identical once ts_arrival and the port of remote are masked (every line; see the comment at the top for what that port is)"
else
  echo "RESULT: DIFFERENT"
  diff "$tmp/before" "$tmp/after" || true
  exit 1
fi
echo "unmasked, $(diff ledger-before.txt ledger-after.txt | grep -c '^<' || true) of $(grep -c '^{' ledger-before.txt) lines differ between the two files: every line by the clock, the lines of a real connection by the loopback's port too, and by nothing else, as the masked comparison shows"
echo "the masked lines, as compared:"
cat "$tmp/after"
