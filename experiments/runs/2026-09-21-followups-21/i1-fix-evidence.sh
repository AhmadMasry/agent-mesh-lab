#!/usr/bin/env bash
# Follow-ups 21, the review round of 2026-09-21: the evidence for I-1, the anonymity clause on the ledgers
# target's taskId arm, and for M-2, detecting a jq failure in the taskId pass.
#
# Four forms of the SAME recipe are compared, so that what is measured is the one clause in each case:
#   A "work-item only"   -- the recipe before this branch, from the parent commit's Makefile blob;
#   B "no anonymity"     -- the shipped recipe with the anonymity clause deleted. This is the first form of this
#                           branch's sel(), the one the review found; it is reconstructed mechanically, by the
#                           substitution printed below, rather than fetched by SHA, so this reading can be re-run
#                           after the amend that carries the fix;
#   M "old jq guard"     -- the shipped recipe with the taskId pass's error handling put back to the reviewed
#                           shape, where the `||` took `sort -u`'s status instead of jq's;
#   C "shipped"          -- the working tree's Makefile, unmodified.
#
# Part 1, on the LIVE pods (read-only: `make ledgers` reads `kubectl logs` and writes nothing): the work items
# the record already cites, collected by A, B and C and compared byte for byte. C must equal B on every one of
# them -- that is what "the fix changes nothing that was counted" means -- and both must keep the four
# resubscription execution lines that A drops.
# Part 2, on a SYNTHETIC log through a stand-in `kubectl` (scratch only, no cluster): the case the review named
# and the record did not cover -- two work items touching ONE Task, the second naming a work item of its own.
# Part 3, M-2: a stand-in `jq` that fails, run against M and C.
#
# Keep-awake: this script starts none and changes no power setting. No retry logic; each collection runs once.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
D=experiments/runs/2026-09-21-followups-21
SCR="${TMPDIR%/}/fu21/i1"
rm -rf "$SCR"; mkdir -p "$SCR/bin" "$SCR/logs" "$SCR/out"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

PARENT=$(git rev-parse HEAD^)
git show "$PARENT:Makefile" > "$SCR/Makefile.A"
cp Makefile "$SCR/Makefile.C"
python3 - "$SCR/Makefile.C" "$SCR/Makefile.B" "$SCR/Makefile.M" <<'PY'
import sys, pathlib

src = pathlib.Path(sys.argv[1]).read_text()

# B: the anonymity clause deleted, and nothing else.
with_clause = 'or ((.logical_work_item_id // "") == "" and ((.taskId // "") as $$id | $$id != "" and ($$t | index($$id)) != null)))'
without = 'or ((.taskId // "") as $$id | $$id != "" and ($$t | index($$id)) != null))'
assert src.count(with_clause) == 1, "the anonymity clause is not where this script expects it"
pathlib.Path(sys.argv[2]).write_text(src.replace(with_clause, without, 1))
print("# B built from C by deleting exactly one substring:")
print("#   -  " + with_clause)
print("#   +  " + without)

# M: the taskId pass's error handling put back to the reviewed shape, line by line, and nothing else.
out, edits = [], []
for line in src.splitlines(keepends=True):
    if line.startswith("\tTASKIDS_RAW=$$( {"):
        out.append(line.replace("TASKIDS_RAW=$$( {", "TASKIDS=$$( {", 1))
        edits.append("TASKIDS_RAW=  ->  TASKIDS=")
    elif line.lstrip().startswith("| jq -R -r --arg lwi") and line.rstrip().endswith("' ) \\"):
        out.append(line.replace("' ) \\", "' \\", 1))
        edits.append("jq line: the subshell no longer closes on it")
    elif line.lstrip().startswith('|| { echo "ledgers: jq failed while mapping'):
        out.append(line.replace("|| {", "| sort -u ) || {", 1))
        edits.append("guard line: sort -u moved back inside the substitution, before the ||")
    elif line.startswith("\tTASKIDS=$$(printf"):
        edits.append("dropped: the separate sort -u assignment")
    else:
        out.append(line)
assert len(edits) == 4, "the taskId pass is not where this script expects it: %s" % edits
pathlib.Path(sys.argv[3]).write_text("".join(out))
print("# M built from C by four line edits and nothing else:")
for e in edits:
    print("#   " + e)
PY

echo "# follow-ups 21, I-1 and M-2 evidence. start $(ts)"
echo "# HEAD $(git rev-parse HEAD); parent $PARENT"
echo "# A = parent blob $(git rev-parse "$PARENT:Makefile")   B = shipped minus the anonymity clause"
echo "# M = shipped with the reviewed jq guard              C = the working tree's Makefile"
for v in A B M C; do echo "# sha256  $v $(shasum -a 256 "$SCR/Makefile.$v" | cut -d' ' -f1)"; done

echo
echo "===== part 1: the live pods, read-only, $(ts) ====="
for lwi in fu21-stream-go-022452 g2c-fu21nc-worker g2c-fu21nc-orchestrator; do
	for v in A B C; do
		make -f "$SCR/Makefile.$v" --no-print-directory ledgers "LWI=$lwi" > "$SCR/out/$lwi.$v" 2>"$SCR/out/$lwi.$v.err"
		printf '# %-26s %s exit=%s lines=%s sha256=%s\n' "$lwi" "$v" "$?" \
			"$(wc -l < "$SCR/out/$lwi.$v" | tr -d ' ')" \
			"$(shasum -a 256 "$SCR/out/$lwi.$v" | cut -d' ' -f1)"
	done
	if cmp -s "$SCR/out/$lwi.B" "$SCR/out/$lwi.C"; then echo "#   B vs C: BYTE-IDENTICAL"; else echo "#   B vs C: DIFFERS"; diff -u "$SCR/out/$lwi.B" "$SCR/out/$lwi.C"; fi
	echo "#   SubscribeToTask execution lines: A $(grep -c '"ledger":"execution".*SubscribeToTask' "$SCR/out/$lwi.A") B $(grep -c '"ledger":"execution".*SubscribeToTask' "$SCR/out/$lwi.B") C $(grep -c '"ledger":"execution".*SubscribeToTask' "$SCR/out/$lwi.C")"
done
echo "# and against what this run directory already committed:"
for lwi in fu21-stream-go-022452 g2c-fu21nc-worker g2c-fu21nc-orchestrator; do
	case "$lwi" in
	fu21-stream-go-022452) committed="$D/stream/new-stdout.txt" ;;
	*) committed="$D/stream/unary-$lwi/new-stdout.txt" ;;
	esac
	if cmp -s "$SCR/out/$lwi.C" "$committed"; then echo "#   $lwi: C equals the committed $committed, byte for byte"
	else echo "#   $lwi: C DIFFERS from $committed"; diff -u "$committed" "$SCR/out/$lwi.C"; fi
done

echo
echo "===== part 2: the shared-Task case, synthetic log, no cluster, $(ts) ====="
cat > "$SCR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Stand-in for kubectl: serves a fixture file in place of the worker's pod log, so the real recipe runs off-cluster.
for a in "$@"; do
  case "$a" in
    deploy/worker) cat "$FU21_LOGS/worker.log" 2>/dev/null; exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$SCR/bin/kubectl"
W="$SCR/logs/worker.log"
# WI-A owns Task T-A. WI-FOLLOWUP is a later GetTask on T-A carrying its OWN work item -- the shape no committed
# script sends today and the obvious way to write a B-3 row. WI-B is a second, interleaved Task. WI-NOTASK never
# makes a Task. The SubscribeToTask line is the anonymous resubscription the second arm exists to collect.
printf '%s\n' '{"ledger":"ingress","phase":"arrival","method":"SendMessage","id":"r1","messageId":"m-a","taskId":"","logical_work_item_id":"WI-A"}' > "$W"
printf '%s\n' '{"ledger":"execution","event":"received","method":"SendMessage","messageId":"m-a","taskId":"T-A","logical_work_item_id":"WI-A"}' >> "$W"
printf '%s\n' '{"ledger":"ingress","phase":"arrival","method":"GetTask","id":"r2","messageId":"","taskId":"T-A","logical_work_item_id":"WI-FOLLOWUP","lwi_source":"header"}' >> "$W"
printf '%s\n' '{"ledger":"execution","event":"received","method":"GetTask","messageId":"","taskId":"T-A","logical_work_item_id":"WI-FOLLOWUP"}' >> "$W"
printf '%s\n' '{"ledger":"execution","event":"received","method":"SubscribeToTask","messageId":"","taskId":"T-A","logical_work_item_id":""}' >> "$W"
printf '%s\n' '{"ledger":"ingress","phase":"arrival","method":"SendMessage","id":"r3","messageId":"m-b","taskId":"","logical_work_item_id":"WI-B"}' >> "$W"
printf '%s\n' '{"ledger":"execution","event":"received","method":"SendMessage","messageId":"m-b","taskId":"T-B","logical_work_item_id":"WI-B"}' >> "$W"
printf '%s\n' '{"ledger":"ingress","phase":"arrival","method":"SendMessage","id":"r4","messageId":"m-n","taskId":"","logical_work_item_id":"WI-NOTASK"}' >> "$W"
printf '%s\n' '{"ledger":"execution","event":"received","method":"SendMessage","messageId":"m-n","taskId":"","logical_work_item_id":"WI-NOTASK"}' >> "$W"
echo "# the synthetic worker log, whole:"
sed 's/^/#   /' "$W"
export FU21_LOGS="$SCR/logs" PATH="$SCR/bin:$PATH"
for lwi in WI-A WI-FOLLOWUP WI-B WI-NOTASK; do
	echo "# collection LWI=$lwi"
	for v in A B C; do
		make -f "$SCR/Makefile.$v" --no-print-directory ledgers "LWI=$lwi" > "$SCR/out/syn.$lwi.$v" 2>/dev/null
		named=$(grep -c -E '"logical_work_item_id":"[^"]+"' "$SCR/out/syn.$lwi.$v" || true)
		own=$(grep -c "\"logical_work_item_id\":\"$lwi\"" "$SCR/out/syn.$lwi.$v" || true)
		anon=$(grep -c '"logical_work_item_id":""' "$SCR/out/syn.$lwi.$v" || true)
		printf '#     %s: %s lines = own %s + anonymous %s + OTHER work items %s\n' \
			"$v" "$(wc -l < "$SCR/out/syn.$lwi.$v" | tr -d ' ')" "$own" "$anon" "$((named - own))"
	done
done

echo
echo "===== part 3: M-2, a failing jq in the taskId pass, $(ts) ====="
# The stand-in fails on its FIRST call only -- the taskId pass -- and hands every later call to the real jq, so
# what is measured is whether that one failure is detected, not whether the whole recipe survives a broken jq.
REALJQ=$(command -v jq)
cat > "$SCR/bin/jq" <<STUB
#!/usr/bin/env bash
# Stand-in for jq: fails once, then delegates. Scratch only.
N="\$SCR_JQ_COUNT"
n=\$(cat "\$N" 2>/dev/null || echo 0)
echo \$((n + 1)) > "\$N"
if [ "\$n" = "0" ]; then echo "jq: simulated failure on the taskId pass" >&2; exit 5; fi
exec $REALJQ "\$@"
STUB
chmod +x "$SCR/bin/jq"
for v in M C; do
	export SCR_JQ_COUNT="$SCR/jq-count.$v"; rm -f "$SCR_JQ_COUNT"
	out=$(make -f "$SCR/Makefile.$v" --no-print-directory ledgers "LWI=WI-A" 2>&1); rc=$?
	printf '# %s: exit=%s; lines collected=%s; the taskId pass reported its failure: %s\n' "$v" "$rc" \
		"$(printf '%s' "$out" | grep -c '"ledger":' || true)" \
		"$(printf '%s' "$out" | grep -q "jq failed while mapping" && echo yes || echo NO)"
	printf '#     jq calls made: %s\n' "$(cat "$SCR_JQ_COUNT" 2>/dev/null || echo 0)"
done
unset SCR_JQ_COUNT
rm -f "$SCR/bin/jq"
echo "# M is the reviewed shape, whose || took the status of sort -u; C is the shipped one, whose || takes the status of jq."
echo "# With the failure confined to the taskId pass, M collects on an empty map and says nothing; C stops."
echo "# done $(ts)"
