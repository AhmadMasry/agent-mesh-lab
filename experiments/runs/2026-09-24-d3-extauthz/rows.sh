#!/usr/bin/env bash
# Follow-on D-3: the rows, in the order the brief and the controller's rulings of 2026-09-24 set, one stage per call.
#   bash rows.sh <stage>
#   p0        nothing applied: per receiver one small curl SendMessage (csm), the JSON shape the padded control uses;
#             the fixture's ledger must stay empty
#   deny      the policy applied (fixture at deny); per receiver: Row 1 (10 each of sm, st, ss by the load client and
#             cst by curl, JSON-RPC); REST and gRPC (5 sm and 5 st each, the load client); Row 3 (pad, padt, padsm);
#             Row 4 (batch, dup)
#   allow     the fixture rolled to EXTAUTHZ_UNDECIDABLE=allow, policy still in force; per receiver Row 3 and Row 4 again
#   unavail   the fixture back at deny, then scaled to 0; per receiver 5 sm and 5 st (JSON-RPC); then scaled to 1, Ready
#   off       the policy removed; readings
#   shapes    added in the review round (review-d3 I1): the policy applied again, fixture at deny; per receiver 5 curl each
#             of the shapes that receiver could dispatch: go xp, xa, xg, xr; py xg, xr (its JSON-RPC route is Starlette's
#             Route("/"), matched by a regex anchored at both ends, so POST /x and POST /a2a/v1 cannot reach dispatch there);
#             then the policy removed
# One fixture setting per window: every send of a window is sent after its setting's rollout finished and before the
# next began, and every decision line carries the setting it was decided under. No retry logic. Keep-awake: this
# script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
RUNREL="${RUNREL:?}"; RUN_ID="${RUN_ID:?}"; IMAGE="${IMAGE:?}"
export RUNREL RUN_ID IMAGE
D="experiments/runs/$RUNREL"
X="bash $D/d3.sh"
REPS=10
REPS_B=5
ts() { date -u +%FT%TZ; }
row34() { # phase
	local r k
	for r in go py; do for k in pad padt padsm batch dup; do $X send "$1" jsonrpc "$k" "$r" 1; done; done
}
STAGE="${1:?stage}"
echo "$(ts) stage $STAGE start" | tee -a "$D/phases.txt"
case "$STAGE" in
p0)
	$X read p0-before
	for r in go py; do $X send p0 jsonrpc csm "$r" 1; done
	;;
deny)
	$X read deny-before
	$X apply
	sleep 8
	$X read deny-applied
	for r in go py; do
		for n in $(seq 1 "$REPS"); do for k in sm st ss cst; do $X send deny jsonrpc "$k" "$r" "$n"; done; done
	done
	$X hop deny-row1
	for b in rest grpc; do for r in go py; do
		for n in $(seq 1 "$REPS_B"); do $X send deny "$b" sm "$r" "$n"; $X send deny "$b" st "$r" "$n"; done
	done; done
	row34 deny
	$X read deny-end
	;;
allow)
	$X setting allow
	$X read allow-applied
	row34 allow
	$X read allow-end
	;;
unavail)
	$X setting deny
	$X read deny-restored
	$X scale 0
	$X read unavail-scaled-0
	for r in go py; do
		for n in $(seq 1 "$REPS_B"); do $X send unavail jsonrpc sm "$r" "$n"; $X send unavail jsonrpc st "$r" "$n"; done
	done
	$X read unavail-end
	$X scale 1
	$X read unavail-restored
	;;
shapes)
	$X read shapes-before
	$X apply
	sleep 8
	$X read shapes-applied
	for n in $(seq 1 5); do for k in xp xa xg xr; do $X send shapes jsonrpc "$k" go "$n"; done; done
	for n in $(seq 1 5); do for k in xg xr; do $X send shapes jsonrpc "$k" py "$n"; done; done
	$X read shapes-end
	$X remove
	sleep 8
	$X read shapes-removed
	;;
off)
	$X remove
	sleep 8
	$X read removed
	;;
*) echo "stage $STAGE" >&2; exit 1 ;;
esac
echo "$(ts) stage $STAGE end" | tee -a "$D/phases.txt"
