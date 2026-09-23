#!/usr/bin/env bash
# Experiment C, step C-8: the order the step ran in, one stage per call, so that a stage can be read before the next.
#   run-c8.sh before | deny | row1 | deny-probes | deny-off | require | row2 | require-probes | require-off | after
#             then pod-up | deny2 | deny2-probe | deny2-off | scoped | row5 | scoped-probes | scoped-off | after2
# Rows 1 and 2 are C-6's sends.sh (per receiver: sm SendMessage, st SubscribeToTask naming no task, ss
# SendStreamingMessage, all by the load client; cst SubscribeToTask by curl with curl's own headers, Accept: */*), run
# from C-6's run directory with RUNREL set to this one and the load client image C-6 resolved (its image.txt), as
# C-7 did. Row 3 (pad) and row 4 (batch, dup) are c8.sh probe. One send per Job or curl, nothing re-sent.
# No retry logic anywhere. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
export RUNREL=2026-09-23-c8-body-rule RUN_ID=c8a
D="experiments/runs/$RUNREL"
C6=experiments/runs/2026-09-23-c6-httproute
IMAGE=$(sed -n 's/.* image=\([^ ]*\) .*/\1/p' "$C6/image.txt" | tail -1)
export IMAGE
C8="bash $D/c8.sh"
SENDS="bash $C6/sends.sh"
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
mark() { echo "$(date -u +%FT%TZ) stage $1" | tee -a "$D/phases.txt"; }
rows() { # rows <phase> <n>
	local n recv kind
	for n in $(seq 1 "$2"); do
		for recv in go py; do
			for kind in sm st ss cst; do $SENDS "$1" "$kind" "$recv" "$n"; done
		done
	done
}
stage="${1:?stage}"
case "$stage" in
before) mark before; echo "image $IMAGE" >> "$D/phases.txt"; $C8 read before "$(date -u -v-5M +%FT%TZ)"; $SENDS pod-up ;;
deny) mark deny; t=$(tsn); echo "$t" > "${TMPDIR%/}/c8/deny-since"; $C8 apply overlay-c8-deny; sleep 10; $C8 read deny-applied "$t" ;;
row1) mark row1; rows c8d 10 ;;
deny-probes)
	mark deny-probes
	for recv in go py; do $C8 probe c8d pad "$recv" 1; done
	for recv in go py; do $C8 probe c8d batch "$recv" 1; $C8 probe c8d dup "$recv" 1; done ;;
deny-off) mark deny-off; t=$(tsn); $C8 read deny-end "$(cat "${TMPDIR%/}/c8/deny-since")"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny-removed "$t" ;;
require) mark require; t=$(tsn); echo "$t" > "${TMPDIR%/}/c8/require-since"; $C8 apply overlay-c8-require; sleep 10; $C8 read require-applied "$t" ;;
row2) mark row2; rows c8r 5 ;;
require-probes) mark require-probes; for recv in go py; do $C8 probe c8r pad "$recv" 1; done ;;
require-off) mark require-off; t=$(tsn); $C8 read require-end "$(cat "${TMPDIR%/}/c8/require-since")"; $C8 remove overlay-c8-require; sleep 10; $C8 read require-removed "$t" ;;
after)
	mark after
	$SENDS pod-down
	RUN_ID=c8after RUN_ITEM="$RUNREL/after" bash experiments/gate2-single-clean.sh > "$D/after-driver.txt" 2>&1
	echo "$(date -u +%FT%TZ) clean check exit=$?" | tee -a "$D/phases.txt"
	$C8 read after "$(date -u -v-3M +%FT%TZ)" ;;
# Added after the controller's rulings of 2026-09-23: the Python pad in the tenant field under Deny re-applied
# (phase c8p), and a Require whose first term exempts a bodyless request (phase c8s), then a second clean check.
deny2) mark deny2; t=$(tsn); echo "$t" > "${TMPDIR%/}/c8/deny2-since"; $C8 apply overlay-c8-deny; sleep 10; $C8 read deny2-applied "$t" ;;
deny2-probe) mark deny2-probe; $C8 probe c8p padt py 1 ;;
deny2-off) mark deny2-off; t=$(tsn); $C8 read deny2-end "$(cat "${TMPDIR%/}/c8/deny2-since")"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny2-removed "$t" ;;
scoped) mark scoped; t=$(tsn); echo "$t" > "${TMPDIR%/}/c8/scoped-since"; $C8 apply overlay-c8-require-scoped; sleep 10; $C8 read scoped-applied "$t" ;;
row5) mark row5; rows c8s 5 ;;
scoped-probes) mark scoped-probes; for recv in go py; do $C8 probe c8s pad "$recv" 1; done ;;
scoped-off) mark scoped-off; t=$(tsn); $C8 read scoped-end "$(cat "${TMPDIR%/}/c8/scoped-since")"; $C8 remove overlay-c8-require-scoped; sleep 10; $C8 read scoped-removed "$t" ;;
after2)
	mark after2
	$SENDS pod-down
	RUN_ID=c8after2 RUN_ITEM="$RUNREL/after-2" bash experiments/gate2-single-clean.sh > "$D/after-2-driver.txt" 2>&1
	echo "$(date -u +%FT%TZ) clean check 2 exit=$?" | tee -a "$D/phases.txt"
	$C8 read after-2 "$(date -u -v-3M +%FT%TZ)" ;;
pod-up) mark pod-up; $SENDS pod-up ;;
*) echo "stage $stage" >&2; exit 1 ;;
esac
# The -end readings take their log window from the overlay's apply stamp (kept in the scratch directory), so that
# every non-request line either proxy wrote while the rule was in force is in them.
