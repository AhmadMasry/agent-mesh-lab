#!/usr/bin/env bash
# Follow-on D-3b: the rows, in the order the brief sets, one stage per call. Adapted from
# experiments/runs/2026-09-24-d3-extauthz/rows.sh, changed in: this header, d3b.sh for d3.sh, the shapes stage (D-3's four
# and D-3b's, 5 each per receiver where that receiver dispatches the shape, read from both receivers' routing), and the
# stages D-3b does not repeat (p0, unavail) left out. The unavailable row is not repeated: the proxy's failure mode with
# no authorizer does not depend on the fixture's code.
#   bash rows.sh <stage>
#   deny      the policy applied from the run directory (fixture at deny); per receiver: Row 1 (10 each of sm, st, ss by the
#             load client and cst by curl, JSON-RPC); REST and gRPC (5 sm and 5 st each, the load client); Row 3 (pad,
#             padt, padsm); Row 4 (batch, dup)
#   shapes    the policy still in force, fixture at deny: per receiver 5 curl each of the shapes it dispatches:
#             go  xp xa xg xr xn xt xm xc xh xl gp gs gq xu xq xi rg xk   (18)
#             py  xg xr xn xc xh xl xs xe xb x16 xq rg xk                  (13)
#   allow     the fixture rolled to EXTAUTHZ_UNDECIDABLE=allow, policy still in force; per receiver Row 3 and Row 4 again
#   restore   the fixture set back to deny; the policy removed; readings
# One fixture setting per window: every send of a window is sent after its setting's rollout finished and before the
# next began, and every decision line carries the setting it was decided under. No retry logic. Keep-awake: this
# script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
RUNREL="${RUNREL:?}"; RUN_ID="${RUN_ID:?}"; IMAGE="${IMAGE:?}"
export RUNREL RUN_ID IMAGE
D="experiments/runs/$RUNREL"
X="bash $D/d3b.sh"
REPS=10
REPS_B=5
REPS_S=5
GO_SHAPES="xp xa xg xr xn xt xm xc xh xl gp gs gq xu xq xi rg xk"
PY_SHAPES="xg xr xn xc xh xl xs xe xb x16 xq rg xk"
ts() { date -u +%FT%TZ; }
row34() { # phase
	local r k
	for r in go py; do for k in pad padt padsm batch dup; do $X send "$1" jsonrpc "$k" "$r" 1; done; done
}
STAGE="${1:?stage}"
echo "$(ts) stage $STAGE start" | tee -a "$D/phases.txt"
case "$STAGE" in
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
shapes)
	$X read shapes-before
	for n in $(seq 1 "$REPS_S"); do for k in $GO_SHAPES; do $X send shapes jsonrpc "$k" go "$n"; done; done
	for n in $(seq 1 "$REPS_S"); do for k in $PY_SHAPES; do $X send shapes jsonrpc "$k" py "$n"; done; done
	$X read shapes-end
	;;
allow)
	$X setting allow
	$X read allow-applied
	row34 allow
	$X read allow-end
	;;
restore)
	$X setting deny
	$X read deny-restored
	$X remove
	sleep 8
	$X read removed
	;;
*) echo "stage $STAGE" >&2; exit 1 ;;
esac
echo "$(ts) stage $STAGE end" | tee -a "$D/phases.txt"
