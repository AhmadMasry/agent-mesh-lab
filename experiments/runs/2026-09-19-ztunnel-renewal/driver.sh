#!/bin/bash
# Follow-ups 16, phase 2 — the detached driver for the ztunnel certificate-renewal measurement
# across a forced host sleep.
#
# Written for bash 3.2 (macOS /bin/bash 3.2.57 is the only bash on the lab host): no associative
# arrays, no mapfile, no printf %(...)T, no wait -n, no empty-array expansion under `set -u`.
#
#   driver.sh preflight <RUN_DIR>   read-only checks; writes <RUN_DIR>/preflight.txt; exit 60 on a FAIL
#   driver.sh run       <RUN_DIR>   Setup -> arm C -> arm T -> arm P4 -> Restore, by itself
#   driver.sh restore   <RUN_DIR>   standalone, idempotent: the committed ztunnel values, read back
#   driver.sh status    <RUN_DIR>   where the run is
#
# RUN_DIR may also come from the environment. The repository root is REPO_ROOT, or else the nearest
# directory above this script that holds CLAUDE.md, the Makefile and the committed ztunnel values.
#
# Start it detached, so that no terminal, agent turn or API connection is needed afterwards:
#   nohup /bin/bash driver.sh run "$RUN_DIR" >>"$RUN_DIR/driver.out" 2>&1 &
#
# What it changes on the cluster, and nothing else: one helm upgrade of the ztunnel release with a
# throwaway second values file (env.SECRET_TTL=10m, logLevel with identity=debug), one probe pod in `lab`,
# one `rollout restart ds/ztunnel` (arm P4), and the helm upgrade back to the committed values alone,
# read back. It runs no make target. It starts no keep-awake and changes no power setting.
#
# No retry rule (CLAUDE.md rule 4): the in-mesh probe is one curl per minute with --retry 0 and no
# loop on failure; every instrument read is a single bounded call whose failure is recorded as a row.
# The one repeated action is the restore's helm upgrade (RESTORE_ATTEMPTS, default 3, each recorded):
# it is the lab's configuration being put back, not a measured request.
#
# Exit codes: 0 all arms ran and the restore was read back; 10 ABORT honoured and restore read back;
# 20 the forced sleep was not produced (P4 and restore done); 30 the P1 gate failed after arm C
# (restore done); 40 Setup failed (restore done); 50 the restore could not be read back
# (RESTORE-FAILED holds the reason); 60 preflight failed (nothing applied); 64 usage;
# 130/143 INT/TERM (restore attempted through the trap).

set -u
set -o pipefail
umask 022
export LC_ALL=C

# ------------------------------------------------------------------------------------------------
# Configuration. Every value can be set from the environment; the defaults are the design's.
# ------------------------------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-agent-mesh-lab}"
KCTX="${KCTX:-kind-${CLUSTER_NAME}}"
NODE_W="${NODE_W:-${CLUSTER_NAME}-worker}"
NODE_CP="${NODE_CP:-${CLUSTER_NAME}-control-plane}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
LAB_NS="${LAB_NS:-lab}"
TRACK_ID="${TRACK_ID:-spiffe://cluster.local/ns/lab/sa/default}"
TRACK_NODE="${TRACK_NODE:-$NODE_W}"
VALUES_REL="deploy/step-2-ambient-agw/ztunnel-values.yaml"

OVERRIDE_TTL="${OVERRIDE_TTL:-10m}"
OVERRIDE_RUST_LOG="${OVERRIDE_RUST_LOG:-info,ztunnel::identity=debug}"
BACKDATE_S=120                       # istiod's ClockSkewGracePeriod, generate_cert.go 283-285 at 1.31.0

PROBE_POD="${PROBE_POD:-zt-probe}"
PROBE_URL="${PROBE_URL:-http://worker.lab.svc.cluster.local:8080/.well-known/agent-card.json}"
PROBE_CURL_FLAGS="-sS --retry 0 --max-time 10 -o /dev/null -w %{http_code},%{time_total}"

LOOP_PERIOD="${LOOP_PERIOD:-5}"              # seconds; the wake detector's resolution (<= 10)
GAP_THRESHOLD="${GAP_THRESHOLD:-60}"         # a host-clock step larger than this between two ticks is a gap
LONG_GAP="${LONG_GAP:-900}"                  # a gap this long resets the two-renewals condition
CLOCK_EVERY="${CLOCK_EVERY:-10}";   CLOCK_FAST_EVERY="${CLOCK_FAST_EVERY:-5}";   CLOCK_FAST_FOR="${CLOCK_FAST_FOR:-180}"
CERTS_EVERY="${CERTS_EVERY:-30}";   CERTS_FAST_EVERY="${CERTS_FAST_EVERY:-15}";  CERTS_FAST_FOR="${CERTS_FAST_FOR:-600}"
COUNTERS_EVERY="${COUNTERS_EVERY:-60}"
PROBE_EVERY="${PROBE_EVERY:-60}"

ARM_C_SECS="${ARM_C_SECS:-1800}"             # control arm, awake seconds
T_WAIT_CAP="${T_WAIT_CAP:-300}"              # wait for a renewal before the sleep: one cycle (240 s) plus detection
SLEEP_AFTER_RENEWAL="${SLEEP_AFTER_RENEWAL:-30}"
SLEEP_CONFIRM_SECS="${SLEEP_CONFIRM_SECS:-60}"
NO_GAP_FALLBACK="${NO_GAP_FALLBACK:-1200}"   # a sleep entry was seen but no gap > threshold within this much awake time
T_MIN_AWAKE="${T_MIN_AWAKE:-3900}"           # 65 min of awake time after the first wake
T_MIN_RENEWALS="${T_MIN_RENEWALS:-2}"
T_CAP_AWAKE="${T_CAP_AWAKE:-28800}"          # 8 h of awake time after the first wake
P4_RENEWALS="${P4_RENEWALS:-2}"
P4_CAP_AWAKE="${P4_CAP_AWAKE:-900}"
P1_GATE="${P1_GATE:-strict}"                 # strict: a failed P1 skips arm T (the draft's "stop"); record: note it and go on
P1_MAX_RESIDUAL="${P1_MAX_RESIDUAL:-5}"
P1_MIN_RENEWALS="${P1_MIN_RENEWALS:-3}"
RESTORE_ATTEMPTS="${RESTORE_ATTEMPTS:-3}"
LEAF_TOLERANCE_S="${LEAF_TOLERANCE_S:-120}"

DRY_RUN="${DRY_RUN:-0}"

# ------------------------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------------------------
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"

find_repo_root() {
	if [ -n "${REPO_ROOT:-}" ]; then printf '%s\n' "$REPO_ROOT"; return 0; fi
	local d="$SELF_DIR"
	while [ "$d" != "/" ]; do
		if [ -f "$d/CLAUDE.md" ] && [ -f "$d/Makefile" ] && [ -f "$d/$VALUES_REL" ]; then
			printf '%s\n' "$d"; return 0
		fi
		d="$(dirname "$d")"
	done
	return 1
}

usage() {
	sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'
	exit 64
}

CMD="${1:-}"
RUN_DIR="${2:-${RUN_DIR:-}}"
case "$CMD" in preflight|run|restore|status) ;; *) usage ;; esac
[ -n "$RUN_DIR" ] || { echo "RUN_DIR is required (second argument or environment)" >&2; exit 64; }
mkdir -p "$RUN_DIR" || exit 64
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
REPO_ROOT="$(find_repo_root)" || { echo "repository root not found above $SELF_DIR; set REPO_ROOT" >&2; exit 64; }
VALUES_FILE="$REPO_ROOT/$VALUES_REL"
OVERRIDE_FILE="$RUN_DIR/ztunnel-ttl-override.yaml"
DERIVE="$SELF_DIR/derive-renewals.py"
ERRTMP="$RUN_DIR/.stderr.tmp"
DRY_DIR="$RUN_DIR/.dry"
SIM="${SIM:-$SELF_DIR/test/sim.py}"
FIXTURES="${FIXTURES:-$SELF_DIR/test/fixtures}"
DRY_SCENARIO="${DRY_SCENARIO:-normal}"

dry() { [ "$DRY_RUN" = "1" ]; }

# ------------------------------------------------------------------------------------------------
# Time. Every stamp is UTC from `date -u`. In DRY_RUN the clock is a file that `nap` advances and
# into which the fixtures inject gaps, so the wake detector can be exercised without a sleep.
# ------------------------------------------------------------------------------------------------
now_s() {
	if dry; then local v; read -r v < "$DRY_DIR/now"; printf '%s\n' "$v"; else date -u +%s; fi
}
now_hr() {
	if dry; then local v; read -r v < "$DRY_DIR/now"; printf '%s.000000\n' "$v"; return; fi
	local v; v="$(date -u +%s.%N)"
	case "$v" in
		*N|*.) perl -MTime::HiRes=time -e 'printf "%.6f\n", time' ;;
		*) printf '%s\n' "${v%???}" ;;
	esac
}
epoch_to_utc() { date -u -r "$1" +%FT%TZ; }
epoch_to_pmset_local() { date -r "$1" "+%Y-%m-%d %H:%M:%S"; }
stamp() { if dry; then epoch_to_utc "$(now_s)"; else date -u +%FT%TZ; fi; }
iso_to_epoch() { date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null; }

nap() {
	if dry; then fake_advance "$1"; [ -n "${DRY_REAL_NAP:-}" ] && sleep "$DRY_REAL_NAP"; return 0; fi
	sleep "$1"
}

# DRY_RUN only: advance the fake clock; a pending gap whose start has been reached is applied as a
# host-clock jump, recorded for the simulator (the guest was frozen for that interval) and for the
# canned `pmset -g log`.
fake_advance() {
	local n="$1" t at len
	read -r t < "$DRY_DIR/now"
	t=$((t + n))
	if [ -s "$DRY_DIR/gap-pending" ]; then
		read -r at len < "$DRY_DIR/gap-pending"
		if [ "$t" -ge "$at" ]; then
			printf '%s %s\n' "$at" "$((at + len))" >> "$DRY_DIR/gaps-applied"
			printf '%s +0000 Sleep               \tEntering Sleep state due to %s:TCPKeepAlive=active Using AC (Charge:100%%) %s secs\n' \
				"$(date -u -r "$at" "+%Y-%m-%d %H:%M:%S")" "'Software Sleep pid=1'" "$len" >> "$DRY_DIR/pmset-log-extra"
			printf '%s +0000 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to fixture Using AC (Charge:100%%)\n' \
				"$(date -u -r "$((at + len))" "+%Y-%m-%d %H:%M:%S")" >> "$DRY_DIR/pmset-log-extra"
			t=$((t + len))
			sed -i '' 1d "$DRY_DIR/gap-pending"
		fi
	fi
	printf '%s\n' "$t" > "$DRY_DIR/now.tmp" && mv "$DRY_DIR/now.tmp" "$DRY_DIR/now"
}

# ------------------------------------------------------------------------------------------------
# Logging and markers
# ------------------------------------------------------------------------------------------------
ARM="init"
log() {
	local line; line="$(stamp) [$ARM] $*"
	printf '%s\n' "$line" >> "$RUN_DIR/driver.log"
	if [ -t 1 ]; then printf '%s\n' "$line"; fi
}
atomic_write() { # atomic_write <file> <content>
	printf '%s\n' "$2" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}
set_state() { # set_state <arm> [note]
	ARM="$1"
	local t; t="$(now_s)"
	atomic_write "$RUN_DIR/STATE" "arm=$1 stamp=$(epoch_to_utc "$t") epoch=$t note=${2:-}"
	printf '%s,%s,%s,%s\n' "$t" "$(epoch_to_utc "$t")" "$1" "${2:-}" >> "$RUN_DIR/state-history.csv"
	log "STATE -> $1 ${2:-}"
}

# ------------------------------------------------------------------------------------------------
# Command execution. Nothing below this section calls kubectl, helm, istioctl, docker, pmset or
# osascript except through xread / xmut / xlong, and in DRY_RUN those three never execute: they
# write the command to the log and hand back the simulator's canned reading. The functions just
# below make a direct call visible in DRY_RUN instead of reaching the real tool.
# ------------------------------------------------------------------------------------------------
if dry; then
	_blocked() { printf '%s BLOCKED direct call in DRY_RUN: %s\n' "$(stamp)" "$*" >> "$RUN_DIR/driver.log"; return 99; }
	kubectl()   { _blocked kubectl "$@"; }
	helm()      { _blocked helm "$@"; }
	istioctl()  { _blocked istioctl "$@"; }
	docker()    { _blocked docker "$@"; }
	pmset()     { _blocked pmset "$@"; }
	osascript() { _blocked osascript "$@"; }
	kind()      { _blocked kind "$@"; }
	make()      { _blocked make "$@"; }
fi

# A bounded call. `perl -e 'alarm N; exec ...'` does not bound a Go binary: the Go runtime catches
# SIGALRM and takes no action (tested on this host against a Go child), and kubectl, helm, istioctl
# and docker are Go. So the wrapper forks, waits, and sends TERM then KILL itself.
TO_PERL='my $t=shift; my $pid=fork(); die "fork: $!" unless defined $pid;
if(!$pid){ exec @ARGV; exit 127 }
my $n=0; $SIG{ALRM}=sub{ if($n++==0){ kill "TERM",$pid; alarm 2 } else { kill "KILL",$pid } };
alarm $t; my $r;
while(1){ $r=waitpid($pid,0); last if $r==$pid; next if $!{EINTR}; last }
alarm 0; my $rc=$?; exit(($rc & 127) ? 128+($rc & 127) : $rc>>8);'
to() { perl -e "$TO_PERL" "$@"; }

dry_note() { printf '%s %s\n' "$(stamp)" "$*" >> "$DRY_DIR/commands.log"; }

# xread <timeout_s> cmd...   a read; stdout is the reading; a failure is recorded, never repeated.
xread() {
	local t="$1"; shift
	if dry; then dry_note "read: $*"; dry_feed "$@"; return $?; fi
	local rc
	to "$t" "$@" 2>"$ERRTMP"; rc=$?
	if [ "$rc" -ne 0 ]; then
		{ printf '%s rc=%s cmd=%s\n' "$(stamp)" "$rc" "$*"; head -3 "$ERRTMP" | sed 's/^/    /'; } >> "$RUN_DIR/read-errors.log"
	fi
	return "$rc"
}

# xmut <timeout_s> cmd...    a short command that changes something; command and output are logged.
xmut() {
	local t="$1"; shift
	local out rc
	if dry; then
		log "DRY-RUN would run: $*"; dry_note "mutate: $*"
		out="$(dry_feed "$@" 2>&1)"; rc=$?
	else
		log "run: $*"
		out="$(to "$t" "$@" 2>&1)"; rc=$?
	fi
	printf '%s\n' "$out" | sed 's/^/    | /' >> "$RUN_DIR/driver.log"
	log "rc=$rc"
	XMUT_OUT="$out"
	return "$rc"
}

# xlong <cap_s> <outfile> cmd...   a long command (helm --wait, rollout status). It runs in the
# background while this shell keeps ticking, so the wake detector stays live during it.
xlong() {
	local cap="$1" of="$2"; shift 2
	local rc
	if dry; then
		log "DRY-RUN would run (cap ${cap}s): $*"; dry_note "long: $*"
		dry_feed "$@" > "$of" 2>&1; rc=$?
		nap 20; tick
		log "rc=$rc"
		return "$rc"
	fi
	log "run (cap ${cap}s): $*"
	"$@" > "$of" 2>&1 &
	local pid=$! start; start="$(now_s)"
	XLONG_PID="$pid"
	while kill -0 "$pid" 2>/dev/null; do
		nap 2; tick
		if [ $(( $(now_s) - start )) -ge "$cap" ]; then
			log "cap of ${cap}s reached; terminating pid $pid"
			kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null
			break
		fi
	done
	wait "$pid"; rc=$?
	XLONG_PID=""
	sed 's/^/    | /' "$of" >> "$RUN_DIR/driver.log"
	log "rc=$rc"
	return "$rc"
}

# DRY_RUN: map a command line to a canned reading. Patterns are on the joined argument string.
sim() { DRY_DIR="$DRY_DIR" DRY_SCENARIO="$DRY_SCENARIO" FIXTURES="$FIXTURES" python3 "$SIM" "$@"; }
dry_feed() {
	local c="$*"
	case "$c" in
		*"ztunnel-config certificates --node "*)  sim certs "${c##*--node }" ;;
		*"ztunnel-config log"*)                   sim log-filter ;;
		"istioctl "*"version"*)                   echo "client version: 1.31.0" ;;
		"docker exec "*" uname -r")               echo "6.12.0-fixture-linuxkit" ;;
		"docker exec "*)                          sim clock "$3" ;;
		"docker inspect "*)                       echo "true" ;;
		"docker version"*)                        echo "29.8.0-fixture" ;;
		*"get --raw "*"/proxy/metrics")           sim metrics ;;
		*" exec $PROBE_POD -- curl "*)            sim probe ;;
		*"get nodes "*)                           printf '%s True\n%s True\n' "$NODE_CP" "$NODE_W" ;;
		*"get pods -l app=ztunnel -o jsonpath={range .items[*]}{.metadata.name}{\" \"}{range .spec"*) sim pods-env ;;
		*"get pods -l app=ztunnel "*)             sim ztunnel-pods ;;
		*"get pods -l app=istiod "*)              sim istiod-pod ;;
		*"get ds ztunnel -o jsonpath={range .spec"*) sim ds-env ;;
		*"get ds ztunnel -o jsonpath={.status"*)  sim ds-status ;;
		*"get svc worker "*)                      echo "8080" ;;
		*"get pod $PROBE_POD "*)                  sim probe-pod-phase ;;
		*" run $PROBE_POD "*)                     sim probe-pod-create ;;
		*" delete pod $PROBE_POD "*)              sim probe-pod-delete ;;
		*" wait --for=condition=Ready "*)         echo "pod/$PROBE_POD condition met" ;;
		*" logs "*)                               sim logs "$c" ;;
		*"rollout restart "*)                     sim restart ;;
		*"rollout status "*)                      echo "daemon set \"ztunnel\" successfully rolled out" ;;
		"kubectl "*"version"*)                    echo "Client Version: v1.37.0-fixture" ;;
		"helm "*" upgrade -i ztunnel "*"$OVERRIDE_FILE"*) sim helm-upgrade override ;;
		"helm "*" upgrade -i ztunnel "*)          sim helm-upgrade committed ;;
		"helm "*" get values "*)                  sim helm-values ;;
		"helm "*" history "*)                     sim helm-history ;;
		"helm "*"pull "*)                         sim helm-pull "$RUN_DIR/chart" ;;
		"helm "*"version"*)                       echo "v4.3.0-fixture" ;;
		"pmset -g custom")                        cat "$FIXTURES/pmset-custom.txt" ;;
		"pmset -g batt")                          cat "$FIXTURES/pmset-batt.txt" ;;
		"pmset -g assertions")                    cat "$FIXTURES/pmset-assertions.txt" ;;
		"pmset -g log")                           cat "$FIXTURES/pmset-log-base.txt"; [ -f "$DRY_DIR/pmset-log-extra" ] && cat "$DRY_DIR/pmset-log-extra"; return 0 ;;
		"pmset sleepnow")                         dry_sleep_request sleepnow ;;
		"osascript "*)                            dry_sleep_request osascript ;;
		*) printf 'dry_feed: no canned reading for: %s\n' "$c" >&2; printf '%s UNMAPPED %s\n' "$(stamp)" "$c" >> "$RUN_DIR/driver.log"; return 98 ;;
	esac
}
# DRY_RUN: what a sleep request does is the scenario's fixture: lines "<start offset s> <length s>".
# An empty or absent fixture means the request produced no sleep.
dry_sleep_request() {
	local f="$FIXTURES/scenarios/$DRY_SCENARIO/$1-gaps.txt" t off len
	local rcf="$FIXTURES/scenarios/$DRY_SCENARIO/$1-rc.txt" rc=0
	[ -f "$rcf" ] && read -r rc < "$rcf"
	read -r t < "$DRY_DIR/now"
	if [ -s "$f" ]; then
		while read -r off len; do
			[ -n "$off" ] || continue
			printf '%s %s\n' "$((t + off))" "$len" >> "$DRY_DIR/gap-pending"
		done < "$f"
		echo "fixture: sleep request accepted ($1)"
	else
		echo "fixture: sleep request had no effect ($1)"
	fi
	return "$rc"
}

# ------------------------------------------------------------------------------------------------
# The wake detector and the awake-time accounting
# ------------------------------------------------------------------------------------------------
LAST_TICK=0
FIRST_WAKE=0; SLEEP_ISSUED_AT=0; SLEEP_ENTRY_SEEN=0
AWAKE_SINCE_FIRST_WAKE=0; ARM_AWAKE=0; PHASE_AWAKE=0
GAPS=0; LAST_GAP_END=0; LAST_LONG_GAP_END=0
FAST_CLOCK_UNTIL=0; FAST_CERTS_UNTIL=0
LAST_CLOCK=0; LAST_CERTS=0; LAST_COUNTERS=0; LAST_PROBE=0
LAST_TRACK_SERIAL=""; LAST_RENEWAL_TW=0
RENEWALS_TOTAL=0; RENEWALS_IN_ARM=0; RENEWALS_IN_PHASE=0; RENEWALS_SINCE_REF=0
ISTIOD_POD=""; ISTIOD_RESTARTS=""
T_END_REASON=""; SLEEP_NOT_PRODUCED=0; ABORTED=0

tick() {
	local t d; t="$(now_s)"
	if [ "$LAST_TICK" -gt 0 ]; then
		d=$((t - LAST_TICK))
		if [ "$d" -gt "$GAP_THRESHOLD" ]; then
			on_gap "$LAST_TICK" "$t" "$d"
		elif [ "$d" -gt 0 ]; then
			ARM_AWAKE=$((ARM_AWAKE + d)); PHASE_AWAKE=$((PHASE_AWAKE + d))
			[ "$FIRST_WAKE" -gt 0 ] && AWAKE_SINCE_FIRST_WAKE=$((AWAKE_SINCE_FIRST_WAKE + d))
			[ "$d" -ge 20 ] && log "slow step: $d s between two ticks (below the gap threshold; counted as awake)"
		elif [ "$d" -lt 0 ]; then
			log "host clock went back by $((0 - d)) s between two ticks"
		fi
	fi
	LAST_TICK="$t"
}

on_gap() { # on_gap <before> <after> <seconds>
	GAPS=$((GAPS + 1)); LAST_GAP_END="$2"
	printf '%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$(epoch_to_utc "$1")" "$(epoch_to_utc "$2")" "$ARM" >> "$RUN_DIR/gaps.csv"
	log "GAP $GAPS: host clock stepped $3 s between ticks ($(epoch_to_utc "$1") -> $(epoch_to_utc "$2")); fast sampling starts"
	FAST_CLOCK_UNTIL=$(( $2 + CLOCK_FAST_FOR )); FAST_CERTS_UNTIL=$(( $2 + CERTS_FAST_FOR ))
	if [ "$SLEEP_ISSUED_AT" -gt 0 ] && [ "$FIRST_WAKE" -eq 0 ]; then
		FIRST_WAKE="$2"; AWAKE_SINCE_FIRST_WAKE=0; RENEWALS_SINCE_REF=0
		log "first wake after the forced sleep: $(epoch_to_utc "$2"); gap $3 s"
	fi
	if [ "$3" -ge "$LONG_GAP" ]; then
		LAST_LONG_GAP_END="$2"; RENEWALS_SINCE_REF=0
		log "gap >= ${LONG_GAP}s: the two-renewals count restarts here"
	fi
	mkdir -p "$RUN_DIR/pmset-assertions"
	xread 20 pmset -g assertions > "$RUN_DIR/pmset-assertions/after-gap-$2.txt" 2>&1
}

abort_requested() {
	if [ -f "$RUN_DIR/ABORT" ]; then
		if [ "$ABORTED" -eq 0 ]; then ABORTED=1; log "ABORT file found: going straight to Restore"; fi
		return 0
	fi
	return 1
}

persist_progress() {
	atomic_write "$RUN_DIR/progress.env" "ARM=$ARM
LAST_TICK=$LAST_TICK
LAST_TICK_UTC=$(epoch_to_utc "$LAST_TICK")
SLEEP_ISSUED_AT=$SLEEP_ISSUED_AT
SLEEP_ENTRY_SEEN=$SLEEP_ENTRY_SEEN
FIRST_WAKE=$FIRST_WAKE
GAPS=$GAPS
LAST_GAP_END=$LAST_GAP_END
LAST_LONG_GAP_END=$LAST_LONG_GAP_END
ARM_AWAKE=$ARM_AWAKE
AWAKE_SINCE_FIRST_WAKE=$AWAKE_SINCE_FIRST_WAKE
RENEWALS_TOTAL=$RENEWALS_TOTAL
RENEWALS_IN_ARM=$RENEWALS_IN_ARM
RENEWALS_SINCE_REF=$RENEWALS_SINCE_REF
LAST_TRACK_SERIAL=$LAST_TRACK_SERIAL"
}

# ------------------------------------------------------------------------------------------------
# Instruments
# ------------------------------------------------------------------------------------------------
# Guest clocks, read in one exec so the four values are as close together as one shell allows:
# wall, CLOCK_MONOTONIC (ktime_get: "now at N nsecs" in /proc/timer_list), CLOCK_BOOTTIME
# (/proc/uptime), wall again. An unreadable /proc/timer_list leaves the second field empty.
CLOCK_SH='d1=$(date +%s.%N); m=$(grep -m1 "now at" /proc/timer_list 2>/dev/null | tr -dc 0-9); u=$(cut -d" " -f1 /proc/uptime); d2=$(date +%s.%N); echo "$d1,$m,$u,$d2"'

# The host's own account of its sleep: CLOCK_MONOTONIC keeps counting while the Mac is asleep and
# CLOCK_UPTIME_RAW does not (clock_gettime(3) on macOS), so their difference is the host's total
# sleep since boot. Its change across a gap is the sleep the driver's own gap and pmset's log are
# compared with, and it also shows sleeps shorter than the gap threshold.
host_slept() {
	if dry; then awk '{ s += $2 - $1 } END { printf "%.3f\n", s + 0 }' "$DRY_DIR/gaps-applied"; return; fi
	python3 -c 'import time; print("%.3f" % (time.clock_gettime(time.CLOCK_MONOTONIC) - time.clock_gettime(time.CLOCK_UPTIME_RAW)))' 2>/dev/null
}

sample_clock() {
	local node hb ha out rc slept
	slept="$(host_slept)"
	for node in "$NODE_W" "$NODE_CP"; do
		hb="$(now_hr)"
		out="$(xread 15 docker exec "$node" sh -c "$CLOCK_SH")"; rc=$?
		ha="$(now_hr)"
		case "$out" in *,*,*,*) ;; *) out=",,,"; [ "$rc" -eq 0 ] && rc=97 ;; esac
		printf '%s,%s,%s,%s,%s,%s,%s\n' "$hb" "$ha" "$node" "$out" "$ARM" "$rc" "$slept" >> "$RUN_DIR/clock.csv"
	done
}

sample_certs() {
	local node t out rc
	for node in "$NODE_W" "$NODE_CP"; do
		t="$(now_s)"
		out="$(xread 20 istioctl --context "$KCTX" ztunnel-config certificates --node "$node")"; rc=$?
		if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
			printf '%s,%s,%s,%s,(read-failed),,,,,,,%s\n' "$t" "$(epoch_to_utc "$t")" "$ARM" "$node" "$rc" >> "$RUN_DIR/certs.csv"
			continue
		fi
		printf '%s\n' "$out" | awk -v t="$t" -v u="$(epoch_to_utc "$t")" -v arm="$ARM" -v node="$node" -v rc="$rc" '
			# istioctl 1.31.0 (writer/ztunnel/configdump/certificates.go 62-79): an identity with no certificate
			# chain (Initializing, Unavailable) is one row "<identity> NA <state> false NA NA NA"; it is kept.
			($2 == "Leaf" || $2 == "NA") && NF == 7 { printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", t, u, arm, node, $1, $2, $3, $4, $5, $6, $7, rc; next }
			$2 == "Leaf" || $2 == "NA"              { raw = $0; gsub(/,/, ";", raw); gsub(/  +/, " ", raw); printf "%s,%s,%s,%s,%s,%s,UNPARSED:%s,,,,,%s\n", t, u, arm, node, $1, $2, raw, rc }
		' >> "$RUN_DIR/certs.csv"
		if [ "$node" = "$TRACK_NODE" ]; then track_renewal "$t" "$out"; fi
	done
}

# The live renewal count for the tracked identity on the tracked node: a changed serial. The first
# serial seen after a ztunnel restart is a baseline, not a renewal (LAST_TRACK_SERIAL is cleared there).
track_renewal() { # track_renewal <epoch> <istioctl table>
	local line serial na nb
	line="$(printf '%s\n' "$2" | awk -v id="$TRACK_ID" '$1 == id && $2 == "Leaf" && NF == 7 { print $5, $6, $7; exit }')"
	[ -n "$line" ] || return 0
	read -r serial na nb <<< "$line"
	if [ -n "$LAST_TRACK_SERIAL" ] && [ "$serial" != "$LAST_TRACK_SERIAL" ]; then
		RENEWALS_TOTAL=$((RENEWALS_TOTAL + 1)); RENEWALS_IN_ARM=$((RENEWALS_IN_ARM + 1))
		RENEWALS_IN_PHASE=$((RENEWALS_IN_PHASE + 1)); RENEWALS_SINCE_REF=$((RENEWALS_SINCE_REF + 1))
		local nbe; nbe="$(iso_to_epoch "$nb")"
		if [ -n "$nbe" ]; then LAST_RENEWAL_TW=$((nbe + BACKDATE_S)); else LAST_RENEWAL_TW="$1"; fi
		printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$1" "$(epoch_to_utc "$1")" "$ARM" "$TRACK_NODE" "$TRACK_ID" "$LAST_TRACK_SERIAL" "$serial" "$nb" "$na" >> "$RUN_DIR/renewal-events.csv"
		log "renewal seen: $TRACK_ID on $TRACK_NODE $LAST_TRACK_SERIAL -> $serial (NOT BEFORE $nb; in arm $RENEWALS_IN_ARM, since reference $RENEWALS_SINCE_REF)"
	fi
	LAST_TRACK_SERIAL="$serial"
}

resolve_istiod() {
	local line
	line="$(xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get pods -l app=istiod -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | head -1)"
	read -r ISTIOD_POD ISTIOD_RESTARTS <<< "$line"
	[ -n "$ISTIOD_POD" ]
}

# istiod's CSR counters, read from istiod's own monitoring port through the API server's pod proxy:
#   kubectl get --raw /api/v1/namespaces/istio-system/pods/<istiod pod>:15014/proxy/metrics
# One stateless call; nothing to install in the distroless istiod container, no port-forward
# process to keep alive across a host sleep, and no dependence on Prometheus's scrape, whose last
# sample can be a scrape interval old and whose own clock is the guest's.
sample_counters() {
	local t out rc vals
	t="$(now_s)"
	[ -n "$ISTIOD_POD" ] || resolve_istiod
	out="$(xread 20 kubectl --context "$KCTX" get --raw "/api/v1/namespaces/$ISTIO_NS/pods/$ISTIOD_POD:15014/proxy/metrics")"; rc=$?
	if [ "$rc" -ne 0 ]; then
		printf '%s,%s,%s,%s,%s,,,%s\n' "$t" "$(epoch_to_utc "$t")" "$ARM" "$ISTIOD_POD" "$ISTIOD_RESTARTS" "$rc" >> "$RUN_DIR/csr-counters.csv"
		ISTIOD_POD=""          # resolved again at the next sample, in case istiod was replaced
		return 0
	fi
	vals="$(printf '%s\n' "$out" | awk '
		/^citadel_server_csr_count/                    { a += $NF; fa = 1 }
		/^citadel_server_success_cert_issuance_count/  { b += $NF; fb = 1 }
		END { printf "%s,%s", (fa ? sprintf("%.0f", a) : ""), (fb ? sprintf("%.0f", b) : "") }')"
	printf '%s,%s,%s,%s,%s,%s,%s\n' "$t" "$(epoch_to_utc "$t")" "$ARM" "$ISTIOD_POD" "$ISTIOD_RESTARTS" "$vals" "$rc" >> "$RUN_DIR/csr-counters.csv"
}

# One in-mesh request per minute. curl's retries are off (--retry 0), there is no loop on failure,
# and the flags are in the file's header. A failure is a row.
sample_probe() {
	local t out rc
	t="$(now_s)"
	# shellcheck disable=SC2086
	out="$(xread 25 kubectl --context "$KCTX" -n "$LAB_NS" exec "$PROBE_POD" -- curl $PROBE_CURL_FLAGS "$PROBE_URL")"; rc=$?
	case "$out" in *,*) ;; *) out=","; esac
	printf '%s,%s,%s,%s,%s\n' "$t" "$(epoch_to_utc "$t")" "$ARM" "$rc" "$out" >> "$RUN_DIR/probe.csv"
}

sample_due() {
	local t every
	t="$LAST_TICK"
	every="$CLOCK_EVERY"; [ "$t" -lt "$FAST_CLOCK_UNTIL" ] && every="$CLOCK_FAST_EVERY"
	if [ $((t - LAST_CLOCK)) -ge "$every" ]; then LAST_CLOCK="$t"; sample_clock; tick; fi
	every="$CERTS_EVERY"; [ "$t" -lt "$FAST_CERTS_UNTIL" ] && every="$CERTS_FAST_EVERY"
	if [ $((t - LAST_CERTS)) -ge "$every" ]; then LAST_CERTS="$t"; sample_certs; tick; fi
	if [ $((t - LAST_COUNTERS)) -ge "$COUNTERS_EVERY" ]; then LAST_COUNTERS="$t"; sample_counters; tick; fi
	if [ $((t - LAST_PROBE)) -ge "$PROBE_EVERY" ]; then LAST_PROBE="$t"; sample_probe; tick; fi
}

# observe <predicate>: the sampling loop. Returns 0 when the predicate holds, 2 on ABORT.
observe() {
	local pred="$1"
	while :; do
		tick
		if abort_requested; then return 2; fi
		sample_due
		persist_progress
		if "$pred"; then return 0; fi
		nap "$LOOP_PERIOD"
	done
}

init_csvs() {
	[ -f "$RUN_DIR/clock.csv" ]    || echo "host_before,host_after,node,guest_wall_1,guest_mono_ns,guest_uptime_s,guest_wall_2,arm,rc,host_slept_total_s" > "$RUN_DIR/clock.csv"
	[ -f "$RUN_DIR/certs.csv" ]    || echo "host_epoch,host_utc,arm,node,identity,type,status,valid,serial,not_after,not_before,rc" > "$RUN_DIR/certs.csv"
	[ -f "$RUN_DIR/csr-counters.csv" ] || {
		echo "# source: kubectl --context $KCTX get --raw /api/v1/namespaces/$ISTIO_NS/pods/<istiod pod>:15014/proxy/metrics ; every series whose name starts with citadel_server_csr_count / citadel_server_success_cert_issuance_count, summed; exact names in istiod-metric-names.txt"
		echo "host_epoch,host_utc,arm,istiod_pod,istiod_restarts,csr_count,success_count,rc"; } > "$RUN_DIR/csr-counters.csv"
	[ -f "$RUN_DIR/probe.csv" ]    || {
		echo "# kubectl -n $LAB_NS exec $PROBE_POD -- curl $PROBE_CURL_FLAGS $PROBE_URL ; retries off (--retry 0); one request per ${PROBE_EVERY}s; no loop on failure; rc is kubectl exec's exit code, which is curl's when the exec itself worked"
		echo "host_epoch,host_utc,arm,rc,http_code,time_total"; } > "$RUN_DIR/probe.csv"
	[ -f "$RUN_DIR/gaps.csv" ]     || echo "gap_start_epoch,gap_end_epoch,gap_s,gap_start_utc,gap_end_utc,arm" > "$RUN_DIR/gaps.csv"
	[ -f "$RUN_DIR/arms.csv" ]     || echo "arm,start_epoch,start_utc,end_epoch,end_utc,awake_s,renewals_seen,note" > "$RUN_DIR/arms.csv"
	[ -f "$RUN_DIR/anchors.csv" ]  || echo "host_epoch,host_utc,reason,node,pod,started_at,restarts" > "$RUN_DIR/anchors.csv"
	[ -f "$RUN_DIR/renewal-events.csv" ] || echo "host_epoch,host_utc,arm,node,identity,prev_serial,new_serial,new_not_before,new_not_after" > "$RUN_DIR/renewal-events.csv"
	[ -f "$RUN_DIR/state-history.csv" ]  || echo "host_epoch,host_utc,arm,note" > "$RUN_DIR/state-history.csv"
}

ARM_START=0
arm_begin() { # arm_begin <arm> [note]
	set_state "$1" "${2:-}"
	ARM_START="$(now_s)"; ARM_AWAKE=0; PHASE_AWAKE=0; RENEWALS_IN_ARM=0; RENEWALS_IN_PHASE=0
}
arm_end() { # arm_end [note]
	local t; t="$(now_s)"
	printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$ARM" "$ARM_START" "$(epoch_to_utc "$ARM_START")" "$t" "$(epoch_to_utc "$t")" "$ARM_AWAKE" "$RENEWALS_IN_ARM" "${1:-}" >> "$RUN_DIR/arms.csv"
	log "arm $ARM ended: awake ${ARM_AWAKE}s, renewals seen $RENEWALS_IN_ARM. ${1:-}"
}

# A ztunnel (re)start is a new wall<->monotonic anchor (time.rs 17-43, manager.rs 570): recorded
# with the pods, and followed at once by a clock sample, which is the anchor offset D is taken from.
record_anchor() { # record_anchor <reason>
	local t; t="$(now_s)"
	xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get pods -l app=ztunnel -o 'jsonpath={range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{" "}{.status.containerStatuses[0].state.running.startedAt}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
		| while read -r node pod started restarts; do
			[ -n "$node" ] || continue
			printf '%s,%s,%s,%s,%s,%s,%s\n' "$t" "$(epoch_to_utc "$t")" "$1" "$node" "$pod" "$started" "$restarts" >> "$RUN_DIR/anchors.csv"
		done
	LAST_TRACK_SERIAL=""
	tick
	sample_clock; LAST_CLOCK="$t"
	tick
}

collect_logs() { # collect_logs <label>: whole logs of the current ztunnel pods and istiod, plus the identity extract
	local label="$1" node pod
	mkdir -p "$RUN_DIR/logs"
	xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get pods -l app=ztunnel -o 'jsonpath={range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{" "}{.status.containerStatuses[0].state.running.startedAt}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' > "$RUN_DIR/.pods.tmp"
	tick
	while read -r node pod _rest; do
		[ -n "$pod" ] || continue
		local short="cp"; [ "$node" = "$NODE_W" ] && short="worker"
		xread 45 kubectl --context "$KCTX" -n "$ISTIO_NS" logs "$pod" --timestamps > "$RUN_DIR/logs/ztunnel-$short.after-$label.log"
		tick
		{ echo "# $pod on $node, whole log at $(stamp), lines matching the identity and TLS patterns; timestamps are the node's (guest) clock"
		  grep -E 'certificate fetch succeeded|certificate renewal failed|certificate fetch failed|new log filter is|unable to prefetch|[Ee]xpired|handshake|tls' "$RUN_DIR/logs/ztunnel-$short.after-$label.log"; } > "$RUN_DIR/ztunnel-$short-identity.after-$label.log"
	done < "$RUN_DIR/.pods.tmp"
	rm -f "$RUN_DIR/.pods.tmp"
	resolve_istiod; tick
	xread 45 kubectl --context "$KCTX" -n "$ISTIO_NS" logs "$ISTIOD_POD" --timestamps > "$RUN_DIR/logs/istiod.after-$label.log"
	tick
	local nw nc
	nw="$(grep -c 'certificate fetch succeeded' "$RUN_DIR/logs/ztunnel-worker.after-$label.log" 2>/dev/null)"; nw="${nw:-0}"
	nc="$(grep -c 'certificate fetch succeeded' "$RUN_DIR/logs/ztunnel-cp.after-$label.log" 2>/dev/null)"; nc="${nc:-0}"
	log "logs collected after $label: $nw 'certificate fetch succeeded' lines on the worker ztunnel, $nc on the control-plane ztunnel"
}

# ------------------------------------------------------------------------------------------------
# Helm: the Makefile's own ztunnel command, its variables read from the Makefile
# ------------------------------------------------------------------------------------------------
ISTIO_CHART_VERSION=""; ISTIO_CHART_REPO=""
read_makefile_pins() {
	ISTIO_CHART_VERSION="$(awk '$1 == "ISTIO_CHART_VERSION" && $2 == ":=" { print $3; exit }' "$REPO_ROOT/Makefile")"
	ISTIO_CHART_REPO="$(awk '$1 == "ISTIO_CHART_REPO" && $2 == ":=" { print $3; exit }' "$REPO_ROOT/Makefile")"
	[ -n "$ISTIO_CHART_VERSION" ] && [ -n "$ISTIO_CHART_REPO" ]
}
makefile_command_unchanged() {
	grep -q 'helm upgrade -i ztunnel ztunnel --repo $(ISTIO_CHART_REPO) --version $(ISTIO_CHART_VERSION)' "$REPO_ROOT/Makefile" \
		&& grep -q -- "-n istio-system -f $VALUES_REL --wait" "$REPO_ROOT/Makefile"
}
helm_upgrade() { # helm_upgrade <outfile> [extra -f file]   (cwd is the repository root, as under make)
	local of="$1" extra="${2:-}"
	if [ -n "$extra" ]; then
		xlong 600 "$of" helm --kube-context "$KCTX" upgrade -i ztunnel ztunnel --repo "$ISTIO_CHART_REPO" --version "$ISTIO_CHART_VERSION" -n "$ISTIO_NS" -f "$VALUES_REL" -f "$extra" --wait
	else
		xlong 600 "$of" helm --kube-context "$KCTX" upgrade -i ztunnel ztunnel --repo "$ISTIO_CHART_REPO" --version "$ISTIO_CHART_VERSION" -n "$ISTIO_NS" -f "$VALUES_REL" --wait
	fi
}
helm_upgrade_from_tgz() { # the same release and values from the chart archive pulled at Setup: no network needed
	local of="$1" tgz
	tgz="$(ls "$RUN_DIR"/chart/ztunnel-*.tgz 2>/dev/null | head -1)"
	[ -n "$tgz" ] || { log "no chart archive under $RUN_DIR/chart; the archive route is not available"; return 1; }
	xlong 600 "$of" helm --kube-context "$KCTX" upgrade -i ztunnel "$tgz" -n "$ISTIO_NS" -f "$VALUES_REL" --wait
}

# The committed values file against `helm get values -o json`. The file is read by a parser for
# the YAML it actually uses (nested maps of scalars, comments, quotes); anything else is an error,
# so a file this parser cannot read fails preflight, before anything is applied.
values_equal() { # values_equal <committed.yaml> <helm-values.json>  -> prints both, exit 0 when equal
	python3 - "$1" "$2" <<'PY'
import json, re, sys
def scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v
def strip_comment(v):
    out, q = [], None
    for i, ch in enumerate(v):
        if q:
            if ch == q: q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or v[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()
def parse(path):
    root, stack = {}, [(-1, None)]
    stack[0] = (-1, root)
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "\t" in line[: len(line) - len(line.lstrip())] or line.lstrip().startswith("- "):
            sys.exit(f"values file line {n}: YAML this reader does not handle: {line!r}")
        m = re.match(r"^( *)([A-Za-z0-9_.\-]+):(.*)$", line)
        if not m:
            sys.exit(f"values file line {n}: YAML this reader does not handle: {line!r}")
        indent, key, val = len(m.group(1)), m.group(2), strip_comment(m.group(3))
        while indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if val.strip() == "":
            parent[key] = {}
            stack.append((indent, parent[key]))
        else:
            parent[key] = scalar(val)
    return root
def norm(x):
    if isinstance(x, dict):
        return {k: norm(v) for k, v in sorted(x.items())}
    if isinstance(x, bool):
        return "true" if x else "false"
    return str(x)
want = norm(parse(sys.argv[1]))
raw = open(sys.argv[2], encoding="utf-8").read().strip()
got = norm(json.loads(raw) if raw and raw != "null" else {})
print("committed:", json.dumps(want, sort_keys=True))
print("helm     :", json.dumps(got, sort_keys=True))
sys.exit(0 if want == got else 1)
PY
}
committed_ttl() { # env.SECRET_TTL from the committed values file
	awk '/^env:/ { e = 1; next } /^[^ #]/ { e = 0 } e && $1 == "SECRET_TTL:" { gsub(/"/, "", $2); print $2; exit }' "$VALUES_FILE"
}
ttl_to_s() { # 168h | 10m | 600s -> seconds; anything else -> empty
	case "$1" in
		*[!0-9hms]*|"") return 1 ;;
	esac
	local n="${1%[hms]}" u="${1##*[0-9]}"
	case "$n" in *[!0-9]*|"") return 1 ;; esac
	case "$u" in h) echo $((n * 3600)) ;; m) echo $((n * 60)) ;; s) echo "$n" ;; *) return 1 ;; esac
}

# The standard lab's DaemonSet carries RUST_LOG from the chart's logLevel ("info" by default), so the
# standard is not "no RUST_LOG" but "the env the committed values render": it is captured at the run's
# preflight (ds-env.standard.txt) and the restore must read back exactly that list.
rust_log_of() { printf '%s\n' "$1" | sed -n 's/^RUST_LOG=//p'; }                 # every RUST_LOG value in an env listing
rust_log_standard() { # rust_log_standard <env listing>: exactly one RUST_LOG entry and no identity/debug directive in it
	[ "$(printf '%s\n' "$1" | grep -c '^RUST_LOG=')" -eq 1 ] || return 1
	case "$(rust_log_of "$1")" in *identity*|*debug*|*trace*) return 1 ;; esac
	return 0
}
ds_env()    { xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get ds ztunnel -o 'jsonpath={range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'; }
ds_status() { xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get ds ztunnel -o 'jsonpath={.status.desiredNumberScheduled} {.status.updatedNumberScheduled} {.status.numberReady} {.status.numberAvailable} {.metadata.generation} {.status.observedGeneration}'; }
pods_env()  { xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get pods -l app=ztunnel -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{range .spec.containers[0].env[*]}{.name}={.value}{";"}{end}{"\n"}{end}'; }

# leaves_ok <expected lifetime s>: every Leaf that either node's ztunnel holds reads VALID CERT true
# with NOT AFTER - NOT BEFORE within the tolerance, no identity is without a chain, and the tracked
# identity is present on the tracked node. A node without any Leaf passes: in this lab the
# control-plane node runs no captured workload and its ztunnel holds no certificate (header line
# only in experiments/runs/2026-09-16-genai-spans/rebuild/istio.txt). Prints what it read.
leaves_ok() {
	local want="$1" node out rc ok=0 n line id valid na nb nae nbe life seen_track=0
	for node in "$NODE_W" "$NODE_CP"; do
		out="$(xread 20 istioctl --context "$KCTX" ztunnel-config certificates --node "$node")"; rc=$?
		echo "## istioctl ztunnel-config certificates --node $node   ($(stamp), rc=$rc)"
		printf '%s\n' "$out"
		n=0
		while read -r line; do
			[ -n "$line" ] || continue
			read -r id valid na nb <<< "$line"
			n=$((n + 1))
			nae="$(iso_to_epoch "$na")"; nbe="$(iso_to_epoch "$nb")"
			if [ -z "$nae" ] || [ -z "$nbe" ]; then echo "   $id: stamps not parsed"; ok=1; continue; fi
			life=$((nae - nbe))
			echo "   $id: VALID CERT $valid, NOT AFTER - NOT BEFORE = ${life}s (expected ${want}s +/- ${LEAF_TOLERANCE_S}s)"
			[ "$valid" = "true" ] || ok=1
			[ "$life" -ge $((want - LEAF_TOLERANCE_S)) ] && [ "$life" -le $((want + LEAF_TOLERANCE_S)) ] || ok=1
			if [ "$node" = "$TRACK_NODE" ] && [ "$id" = "$TRACK_ID" ]; then seen_track=1; fi
		done <<< "$(printf '%s\n' "$out" | awk '$2 == "Leaf" && NF == 7 { print $1, $4, $6, $7 }')"
		if [ "$n" -eq 0 ]; then
			echo "   no Leaf row on $node"
			if [ "$node" = "$TRACK_NODE" ] || [ "$rc" -ne 0 ]; then ok=1; fi
		fi
		if printf '%s\n' "$out" | awk '$2 == "NA" { f = 1 } END { exit !f }'; then echo "   an identity on $node has no certificate chain yet (TYPE NA: Initializing or Unavailable)"; ok=1; fi
	done
	[ "$seen_track" -eq 1 ] || { echo "   $TRACK_ID not present on $TRACK_NODE"; ok=1; }
	return "$ok"
}
wait_leaves() { # wait_leaves <expected lifetime s> <outfile> <cap s>: poll leaves_ok every 10 s (a poll of state, not a repeated request)
	local want="$1" of="$2" cap="$3" start; start="$(now_s)"
	while :; do
		tick
		if leaves_ok "$want" > "$of.tmp" 2>&1; then cat "$of.tmp" >> "$of"; rm -f "$of.tmp"; return 0; fi
		if [ $(( $(now_s) - start )) -ge "$cap" ]; then cat "$of.tmp" >> "$of"; rm -f "$of.tmp"; return 1; fi
		nap 10; tick
	done
}

# ------------------------------------------------------------------------------------------------
# Preflight (reads only)
# ------------------------------------------------------------------------------------------------
PF_FAIL=0; PF_WARN=0
pf() { # pf <PASS|FAIL|WARN|INFO> <text>
	printf '%-4s  %s\n' "$1" "$2" | tee -a "$RUN_DIR/preflight.txt"
	case "$1" in FAIL) PF_FAIL=$((PF_FAIL + 1)) ;; WARN) PF_WARN=$((PF_WARN + 1)) ;; esac
}

do_preflight() {
	PF_FAIL=0; PF_WARN=0
	{ echo; echo "# preflight at $(stamp) (DRY_RUN=$DRY_RUN) run dir $RUN_DIR"; } >> "$RUN_DIR/preflight.txt"
	pf INFO "bash ${BASH_VERSION}; driver $SELF; repository root $REPO_ROOT"
	local tool
	for tool in kubectl helm istioctl docker python3 perl pmset osascript awk sed date; do
		if command -v "$tool" >/dev/null 2>&1 || dry; then :; else pf FAIL "tool not on PATH: $tool"; fi
	done
	[ -f "$DERIVE" ] && pf PASS "derive script present: $DERIVE" || pf FAIL "derive script missing: $DERIVE"
	[ -f "$VALUES_FILE" ] && pf PASS "committed values present: $VALUES_REL" || pf FAIL "committed values missing: $VALUES_FILE"
	if read_makefile_pins; then pf PASS "Makefile pins: ISTIO_CHART_VERSION=$ISTIO_CHART_VERSION ISTIO_CHART_REPO=$ISTIO_CHART_REPO"; else pf FAIL "ISTIO_CHART_VERSION / ISTIO_CHART_REPO not read from the Makefile"; fi
	if makefile_command_unchanged; then pf PASS "the Makefile's ztunnel helm command has the form this driver reproduces"; else pf FAIL "the Makefile's ztunnel helm command is not the form this driver reproduces; read the Makefile and this script together"; fi
	local ttl ttl_s
	ttl="$(committed_ttl)"; ttl_s="$(ttl_to_s "$ttl")"
	if [ -n "$ttl_s" ]; then pf PASS "committed SECRET_TTL=$ttl (${ttl_s}s; leaves expected at $((ttl_s + BACKDATE_S))s)"; else pf FAIL "committed SECRET_TTL not read or not parsed: '$ttl'"; fi
	local img; img="$(sed -n 's/^curl-image:.*value: "\([^"]*\)".*/\1/p' "$REPO_ROOT/versions.yaml" | head -1)"
	if [ -n "$img" ]; then pf PASS "probe image from versions.yaml curl-image: $img"; else pf FAIL "curl-image not read from versions.yaml"; fi
	pf INFO "probe: kubectl -n $LAB_NS exec $PROBE_POD -- curl $PROBE_CURL_FLAGS $PROBE_URL"

	# power
	local batt acsleep
	batt="$(xread 20 pmset -g batt | head -1)"
	case "$batt" in *"AC Power"*) pf PASS "power source: $batt" ;; *) pf FAIL "the host is not on AC: $batt" ;; esac
	xread 20 pmset -g custom > "$RUN_DIR/pmset-custom.preflight.txt" 2>&1
	acsleep="$(awk '/^AC Power:/ { s = 1; next } /^[A-Za-z].*:$/ { s = 0 } s && $1 == "sleep" { print $2; exit }' "$RUN_DIR/pmset-custom.preflight.txt")"
	if [ "$acsleep" = "0" ]; then pf PASS "pmset -g custom: AC sleep 0 (no idle sleep on AC; no keep-awake needed)"; else pf FAIL "pmset -g custom: AC sleep is '$acsleep', not 0: stop and ask"; fi
	xread 20 pmset -g assertions > "$RUN_DIR/pmset-assertions.preflight.txt" 2>&1
	local pss; pss="$(awk '$1 == "PreventSystemSleep" { print $2; exit }' "$RUN_DIR/pmset-assertions.preflight.txt")"
	if [ "${pss:-0}" = "0" ]; then pf PASS "pmset -g assertions: PreventSystemSleep 0 (snapshot saved)"; else pf WARN "pmset -g assertions: PreventSystemSleep $pss; whether it blocks a forced sleep is measured, not assumed (snapshot saved)"; fi
	pf INFO "PreventUserIdleSystemSleep $(awk '$1 == "PreventUserIdleSystemSleep" { print $2; exit }' "$RUN_DIR/pmset-assertions.preflight.txt") (an idle-sleep assertion; IOPMLib.h: the system may still sleep for other reasons)"

	# cluster
	local nodes
	nodes="$(xread 20 kubectl --context "$KCTX" get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')"
	for tool in "$NODE_W" "$NODE_CP"; do
		if printf '%s\n' "$nodes" | grep -qx "$tool True"; then pf PASS "node $tool Ready (context $KCTX)"; else pf FAIL "node $tool not Ready or not found in context $KCTX"; fi
	done
	local zp; zp="$(xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get pods -l app=ztunnel -o 'jsonpath={range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{" "}{.status.containerStatuses[0].state.running.startedAt}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}')"
	if [ "$(printf '%s\n' "$zp" | grep -c .)" -eq 2 ] && printf '%s\n' "$zp" | grep -q "^$NODE_W " && printf '%s\n' "$zp" | grep -q "^$NODE_CP "; then
		pf PASS "two ztunnel pods, one per node: $(printf '%s' "$zp" | tr '\n' ';')"
	else
		pf FAIL "expected one ztunnel pod on each of the two nodes, read: $(printf '%s' "$zp" | tr '\n' ';')"
	fi
	xread 30 helm --kube-context "$KCTX" get values ztunnel -n "$ISTIO_NS" -o json > "$RUN_DIR/.helm-values.json" 2>/dev/null
	if values_equal "$VALUES_FILE" "$RUN_DIR/.helm-values.json" > "$RUN_DIR/.values-cmp.txt" 2>&1; then
		pf PASS "helm values of release ztunnel equal the committed file alone: $(sed -n 2p "$RUN_DIR/.values-cmp.txt")"
	else
		pf FAIL "helm values of release ztunnel differ from the committed file: $(tr '\n' ' ' < "$RUN_DIR/.values-cmp.txt")"
	fi
	local env; env="$(ds_env)"
	if printf '%s\n' "$env" | grep -qx "SECRET_TTL=$ttl" && rust_log_standard "$env"; then
		pf PASS "DaemonSet env: SECRET_TTL=$ttl, one RUST_LOG entry, RUST_LOG=$(rust_log_of "$env") (the chart's logLevel; no identity or debug directive)"
		if [ ! -f "$RUN_DIR/ds-env.standard.txt" ]; then printf '%s\n' "$env" | sort > "$RUN_DIR/ds-env.standard.txt"; pf INFO "the standard DaemonSet env captured for the restore's readback: ds-env.standard.txt ($(grep -c . "$RUN_DIR/ds-env.standard.txt") entries)"; fi
	else
		pf FAIL "DaemonSet env is not the committed one: $(printf '%s' "$env" | grep -E '^(SECRET_TTL|RUST_LOG)=' | tr '\n' ' ')"
	fi
	if [ -n "$ttl_s" ] && leaves_ok $((ttl_s + BACKDATE_S)) > "$RUN_DIR/certificates.preflight.txt" 2>&1; then
		pf PASS "every leaf held by either node's ztunnel VALID CERT true at the committed lifetime; $TRACK_ID present on $TRACK_NODE (certificates.preflight.txt)"
	else
		pf FAIL "leaves are not all valid at the committed lifetime, or $TRACK_ID is missing on $TRACK_NODE (certificates.preflight.txt)"
	fi

	# guest clocks
	local node out
	for node in "$NODE_W" "$NODE_CP"; do
		out="$(xread 15 docker exec "$node" sh -c "$CLOCK_SH")"
		case "$out" in
			[0-9]*.[0-9]*,[0-9]*,[0-9]*,[0-9]*) pf PASS "$node clocks read (wall, /proc/timer_list monotonic, /proc/uptime, wall): $out" ;;
			[0-9]*.[0-9]*,,[0-9]*,[0-9]*)       pf WARN "$node: /proc/timer_list not readable; D will come from /proc/uptime (CLOCK_BOOTTIME) and the entry must say so: $out" ;;
			*)                                  pf FAIL "$node: clock read failed: '$out'" ;;
		esac
		pf INFO "$node privileged: $(xread 15 docker inspect -f '{{.HostConfig.Privileged}}' "$node")"
	done

	# istiod counters
	if resolve_istiod; then
		pf PASS "istiod pod: $ISTIOD_POD (restarts $ISTIOD_RESTARTS)"
		xread 20 kubectl --context "$KCTX" get --raw "/api/v1/namespaces/$ISTIO_NS/pods/$ISTIOD_POD:15014/proxy/metrics" | grep '^citadel_server_' > "$RUN_DIR/.metrics.tmp"
		{ echo "# read at $(stamp): kubectl --context $KCTX get --raw /api/v1/namespaces/$ISTIO_NS/pods/$ISTIOD_POD:15014/proxy/metrics | grep '^citadel_server_'"
		  cat "$RUN_DIR/.metrics.tmp"; } > "$RUN_DIR/istiod-metric-names.txt"
		local s1 s2
		s1="$(awk '/^citadel_server_csr_count/ { print $1; exit }' "$RUN_DIR/.metrics.tmp")"
		s2="$(awk '/^citadel_server_success_cert_issuance_count/ { print $1; exit }' "$RUN_DIR/.metrics.tmp")"
		if [ -n "$s1" ] && [ -n "$s2" ]; then pf PASS "istiod CSR series as exposed: $s1 and $s2 (istiod-metric-names.txt)"; else pf FAIL "istiod CSR series not found through the pod proxy (csr='$s1' success='$s2')"; fi
		rm -f "$RUN_DIR/.metrics.tmp"
	else
		pf FAIL "istiod pod not found with -l app=istiod in $ISTIO_NS"
	fi

	# probe target and client
	local port; port="$(xread 20 kubectl --context "$KCTX" -n "$LAB_NS" get svc worker -o 'jsonpath={.spec.ports[*].port}')"
	case " $port " in *" 8080 "*) pf PASS "Service $LAB_NS/worker port 8080 exists" ;; *) pf FAIL "Service $LAB_NS/worker port 8080 not found (read '$port')" ;; esac
	local phase; phase="$(xread 20 kubectl --context "$KCTX" -n "$LAB_NS" get pod "$PROBE_POD" --ignore-not-found -o 'jsonpath={.status.phase}')"
	if [ -z "$phase" ]; then pf INFO "probe pod $LAB_NS/$PROBE_POD does not exist; Setup creates it and Restore deletes it"; else pf INFO "probe pod $LAB_NS/$PROBE_POD exists ($phase); it is used as found and left in place"; fi

	# run directory
	if [ -f "$RUN_DIR/ABORT" ]; then pf FAIL "an ABORT file is already in the run directory"; fi
	if [ -f "$RUN_DIR/OVERRIDE-APPLIED" ] && [ ! -f "$RUN_DIR/RESTORE-VERIFIED" ]; then pf FAIL "this run directory holds an override that was never read back as restored; run: driver.sh restore"; fi
	rm -f "$RUN_DIR/.helm-values.json" "$RUN_DIR/.values-cmp.txt"
	pf INFO "preflight: $PF_FAIL fail, $PF_WARN warn"
	[ "$PF_FAIL" -eq 0 ]
}

write_environment() { # write_environment <label>
	{
		echo "## environment at $1, $(stamp)"
		echo "host: $(sw_vers 2>/dev/null | tr '\n' ' ') $(uname -m)"
		echo "Docker Desktop: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Docker.app/Contents/Info.plist 2>/dev/null) build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Docker.app/Contents/Info.plist 2>/dev/null)"
		echo "Docker Desktop settings-store.json UseVirtualizationFramework: $(grep -o '"UseVirtualizationFramework"[^,}]*' "$HOME/Library/Group Containers/group.com.docker/settings-store.json" 2>/dev/null)"
		echo "docker engine: $(xread 20 docker version --format '{{.Server.Version}}')"
		local node
		for node in "$NODE_W" "$NODE_CP"; do
			echo "$node: kernel $(xread 15 docker exec "$node" uname -r); privileged $(xread 15 docker inspect -f '{{.HostConfig.Privileged}}' "$node")"
			tick
		done
		echo "kubectl: $(xread 20 kubectl version --client 2>/dev/null | head -1)"
		echo "helm: $(xread 20 helm version --short)"
		echo "istioctl: $(xread 20 istioctl version --remote=false | head -1)"
		tick
		echo "host clocks: CLOCK_MONOTONIC - CLOCK_UPTIME_RAW (total host sleep since boot) = $(host_slept) s"
		echo "ztunnel pods (node pod startedAt restarts):"
		xread 20 kubectl --context "$KCTX" -n "$ISTIO_NS" get pods -l app=ztunnel -o 'jsonpath={range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{" "}{.status.containerStatuses[0].state.running.startedAt}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | sed 's/^/   /'
		echo "helm history ztunnel:"
		xread 30 helm --kube-context "$KCTX" history ztunnel -n "$ISTIO_NS" | sed 's/^/   /'
		echo
	} >> "$RUN_DIR/environment.txt" 2>&1
}

# ------------------------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------------------------
do_setup() {
	arm_begin Setup
	write_environment "Setup, before the override"
	# The filter goes in through the chart's own key. The ztunnel chart at 1.31.0 always renders
	#   - name: RUST_LOG / value: {{ .Values.logLevel | quote }}      (templates/daemonset.yaml 130-131)
	# and appends the `env` map after it (187-191), so RUST_LOG under `env` would give the container two
	# RUST_LOG entries (rendered locally with `helm template`: lines 112 and 154). With `logLevel` the
	# whole rendering differs from the committed one in two lines: RUST_LOG's value and SECRET_TTL's.
	printf 'logLevel: "%s"\nenv:\n  SECRET_TTL: "%s"\n' "$OVERRIDE_RUST_LOG" "$OVERRIDE_TTL" > "$OVERRIDE_FILE"
	log "override written: $OVERRIDE_FILE"
	mkdir -p "$RUN_DIR/chart"
	if xlong 180 "$RUN_DIR/helm-pull.txt" helm pull ztunnel --repo "$ISTIO_CHART_REPO" --version "$ISTIO_CHART_VERSION" -d "$RUN_DIR/chart"; then
		log "chart archive for the restore's no-network route: $(ls "$RUN_DIR/chart" | tr '\n' ' ') sha256 $(shasum -a 256 "$RUN_DIR"/chart/*.tgz 2>/dev/null | cut -c1-64)"
	else
		log "WARN: helm pull failed; the restore has only the repository route"
	fi
	xread 30 helm --kube-context "$KCTX" history ztunnel -n "$ISTIO_NS" > "$RUN_DIR/helm-history.before.txt" 2>&1

	atomic_write "$RUN_DIR/OVERRIDE-APPLIED" "issued $(stamp): helm upgrade with $OVERRIDE_FILE about to run"
	if ! helm_upgrade "$RUN_DIR/helm-upgrade.override.txt" "$OVERRIDE_FILE"; then log "Setup: the helm upgrade with the override failed"; return 1; fi
	echo "applied $(stamp)" >> "$RUN_DIR/OVERRIDE-APPLIED"
	xlong 300 "$RUN_DIR/rollout.override.txt" kubectl --context "$KCTX" -n "$ISTIO_NS" rollout status ds/ztunnel --timeout=240s || { log "Setup: rollout did not complete"; return 1; }
	record_anchor "setup: helm upgrade with the override"

	local env ok=0
	env="$(ds_env)"; tick
	{ echo "## Setup readbacks, $(stamp)"; echo "-- DaemonSet env:"; printf '%s\n' "$env" | sed 's/^/   /'; } > "$RUN_DIR/setup-readback.txt"
	printf '%s\n' "$env" | grep -qx "SECRET_TTL=$OVERRIDE_TTL" || { log "Setup: DaemonSet env lacks SECRET_TTL=$OVERRIDE_TTL"; ok=1; }
	printf '%s\n' "$env" | grep -qx "RUST_LOG=$OVERRIDE_RUST_LOG" || { log "Setup: DaemonSet env lacks RUST_LOG=$OVERRIDE_RUST_LOG"; ok=1; }
	[ "$(printf '%s\n' "$env" | grep -c '^RUST_LOG=')" -eq 1 ] || { log "Setup: the DaemonSet env does not hold exactly one RUST_LOG entry"; ok=1; }
	{ echo "-- helm get values:"; xread 30 helm --kube-context "$KCTX" get values ztunnel -n "$ISTIO_NS" -o json; echo; echo "-- helm history:"; xread 30 helm --kube-context "$KCTX" history ztunnel -n "$ISTIO_NS"; } >> "$RUN_DIR/setup-readback.txt" 2>&1
	tick
	[ "$ok" -eq 0 ] || return 1

	# The active log filter. ztunnel 1.31.0 logs "new log filter is" only from set_level, that is on
	# a runtime change through the admin endpoint (telemetry.rs 112-132); a filter that comes from
	# RUST_LOG at start logs no such line. `istioctl ztunnel-config log` with no --level posts an
	# empty level, which ztunnel answers with "current log level is <filter>" and changes nothing
	# (admin.rs handle_logging / change_log_level at 1.31.0).
	local filt; filt="$(xread 30 istioctl --context "$KCTX" ztunnel-config log)"; tick
	{ echo "-- istioctl ztunnel-config log (a read: no --level):"; printf '%s\n' "$filt" | sed 's/^/   /'; } >> "$RUN_DIR/setup-readback.txt"
	case "$filt" in *"ztunnel::identity=debug"*) log "Setup: the active filter reads ztunnel::identity=debug" ;; *) log "WARN Setup: the filter readback does not show ztunnel::identity=debug; the debug-line count below decides" ;; esac

	# the probe client
	local phase img
	phase="$(xread 20 kubectl --context "$KCTX" -n "$LAB_NS" get pod "$PROBE_POD" --ignore-not-found -o 'jsonpath={.status.phase}')"
	if [ "$phase" = "Running" ]; then
		log "probe pod $PROBE_POD exists and is Running; used as found"
	else
		img="$(sed -n 's/^curl-image:.*value: "\([^"]*\)".*/\1/p' "$REPO_ROOT/versions.yaml" | head -1)"
		local ov='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"runAsGroup":65532,"fsGroup":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$PROBE_POD"'","image":"'"$img"'","command":["sleep","259200"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":65532,"runAsGroup":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'
		[ -n "$phase" ] && xlong 120 "$RUN_DIR/probe-pod-delete.txt" kubectl --context "$KCTX" -n "$LAB_NS" delete pod "$PROBE_POD" --ignore-not-found --wait=true
		if xlong 120 "$RUN_DIR/probe-pod-run.txt" kubectl --context "$KCTX" -n "$LAB_NS" run "$PROBE_POD" --image="$img" --restart=Never --overrides="$ov" --command -- sleep 259200; then
			atomic_write "$RUN_DIR/PROBE-POD-CREATED" "$(stamp) $LAB_NS/$PROBE_POD image $img"
			xlong 150 "$RUN_DIR/probe-pod-wait.txt" kubectl --context "$KCTX" -n "$LAB_NS" wait --for=condition=Ready "pod/$PROBE_POD" --timeout=120s || log "WARN Setup: probe pod not Ready; probe rows will show it"
		else
			log "WARN Setup: probe pod not created; probe rows will show it"
		fi
	fi

	# first leaves at the override's lifetime
	local ttl_s; ttl_s="$(ttl_to_s "$OVERRIDE_TTL")"
	if wait_leaves $((ttl_s + BACKDATE_S)) "$RUN_DIR/certificates.setup.txt" 180; then
		log "Setup: every leaf read $((ttl_s + BACKDATE_S))s (NOT AFTER - NOT BEFORE), VALID CERT true (certificates.setup.txt)"
	else
		log "Setup: leaves at the override's lifetime were not read back within 180 s (certificates.setup.txt)"; return 1
	fi
	collect_logs Setup
	local dw dc nf
	dw="$(grep -c 'certificate fetch succeeded' "$RUN_DIR/logs/ztunnel-worker.after-Setup.log" 2>/dev/null)"; dw="${dw:-0}"
	dc="$(grep -c 'certificate fetch succeeded' "$RUN_DIR/logs/ztunnel-cp.after-Setup.log" 2>/dev/null)"; dc="${dc:-0}"
	nf="$(cat "$RUN_DIR"/logs/ztunnel-*.after-Setup.log 2>/dev/null | grep -c 'new log filter is')"
	{ echo "-- identity debug lines after the restart: worker $dw, control-plane $dc 'certificate fetch succeeded'; 'new log filter is' lines: $nf (none is what telemetry.rs predicts for a filter set by RUST_LOG at start)"; } >> "$RUN_DIR/setup-readback.txt"
	if [ "$dw" -ge 1 ]; then log "Setup: identity debug lines visible on the worker's ztunnel ($dw; control-plane $dc, which holds certificates only if a captured workload runs there)"; else log "WARN Setup: no identity debug line on the worker's ztunnel (worker $dw, control-plane $dc); renewals are still counted from serials and istiod's counters"; fi
	write_environment "Setup, after the override"
	arm_end "override applied and read back"
	return 0
}

# ------------------------------------------------------------------------------------------------
# Arm C, the P1 gate
# ------------------------------------------------------------------------------------------------
pred_arm_c() { [ "$ARM_AWAKE" -ge "$ARM_C_SECS" ]; }
do_arm_c() {
	arm_begin C "control: host awake, instruments only, ${ARM_C_SECS}s"
	observe pred_arm_c; local rc=$?
	collect_logs C
	arm_end "gaps during the control arm so far: $GAPS"
	return "$rc"
}
p1_gate() {
	log "P1 gate: derive over arm C (max |residual| ${P1_MAX_RESIDUAL}s, at least $P1_MIN_RENEWALS renewals of the tracked identity, no VALID CERT false reading)"
	python3 "$DERIVE" "$RUN_DIR" --gate-arm C --max-abs-residual "$P1_MAX_RESIDUAL" --min-renewals "$P1_MIN_RENEWALS" \
		--track-id "$TRACK_ID" --track-node "$TRACK_NODE" > "$RUN_DIR/p1-gate.txt" 2>&1
	local rc=$?
	tail -8 "$RUN_DIR/p1-gate.txt" | sed 's/^/    | /' >> "$RUN_DIR/driver.log"
	if [ "$rc" -eq 0 ]; then log "P1 gate: passed"; return 0; fi
	if [ "$P1_GATE" = "record" ]; then log "P1 gate: FAILED (rc=$rc); P1_GATE=record, so arm T runs and the entry reports both"; return 0; fi
	log "P1 gate: FAILED (rc=$rc); P1_GATE=strict: arm T is skipped, as the design's P1 says"
	return 1
}

# ------------------------------------------------------------------------------------------------
# Arm T
# ------------------------------------------------------------------------------------------------
pred_t_wait() {
	if [ "$RENEWALS_IN_PHASE" -ge 1 ] && [ "$LAST_TICK" -ge $((LAST_RENEWAL_TW + SLEEP_AFTER_RENEWAL)) ]; then return 0; fi
	[ "$PHASE_AWAKE" -ge "$T_WAIT_CAP" ]
}
pred_t_done() {
	if [ "$FIRST_WAKE" -eq 0 ]; then
		if [ "$PHASE_AWAKE" -ge "$NO_GAP_FALLBACK" ]; then
			FIRST_WAKE="$LAST_TICK"; AWAKE_SINCE_FIRST_WAKE=0; RENEWALS_SINCE_REF=0
			log "a sleep entry was seen but no gap > ${GAP_THRESHOLD}s within ${NO_GAP_FALLBACK}s of awake time: the observation window starts now, and the record says so"
		fi
		return 1
	fi
	if [ "$AWAKE_SINCE_FIRST_WAKE" -ge "$T_CAP_AWAKE" ]; then T_END_REASON="cap reached: ${T_CAP_AWAKE}s of awake time after the first wake; renewals since the reference gap: $RENEWALS_SINCE_REF"; return 0; fi
	[ "$AWAKE_SINCE_FIRST_WAKE" -ge "$T_MIN_AWAKE" ] || return 1
	[ "$RENEWALS_SINCE_REF" -ge "$T_MIN_RENEWALS" ] || return 1
	T_END_REASON="${AWAKE_SINCE_FIRST_WAKE}s awake since the first wake and $RENEWALS_SINCE_REF renewals of the tracked identity since the last gap >= ${LONG_GAP}s"
	return 0
}

last_sleep_line() { xread 30 pmset -g log | grep 'Entering Sleep' | tail -1; }

# confirm_sleep <previous last "Entering Sleep" line>: up to SLEEP_CONFIRM_SECS of ticking; 0 when a
# gap was detected or a new "Entering Sleep" line is in pmset's log.
confirm_sleep() {
	local prev="$1" waited=0 cur
	while [ "$waited" -lt "$SLEEP_CONFIRM_SECS" ]; do
		nap 2; tick; waited=$((waited + 2))
		if [ "$FIRST_WAKE" -gt 0 ]; then log "sleep produced: a gap followed the request"; return 0; fi
		if [ $((waited % 10)) -eq 0 ]; then
			cur="$(last_sleep_line)"; tick
			if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then SLEEP_ENTRY_SEEN=1; log "sleep produced: pmset log has a new line: $cur"; return 0; fi
		fi
	done
	return 1
}

force_sleep() {
	local prev out rc
	if abort_requested; then return 2; fi
	log "pre-sleep readings: clock, certificates, pmset -g assertions"
	sample_clock; tick; sample_certs; tick
	xread 20 pmset -g assertions > "$RUN_DIR/pmset-assertions.pre-sleep.txt" 2>&1
	prev="$(last_sleep_line)"; tick
	# DRY_RUN test hook: an ABORT that appears after the wait loop has ended and before the request.
	if dry && [ "${DRY_ABORT_AT:-}" = "presleep" ]; then : > "$RUN_DIR/ABORT"; fi
	if abort_requested; then return 2; fi
	{ echo "# forced-sleep attempts; stamps UTC"; } >> "$RUN_DIR/sleep-attempts.txt"

	SLEEP_ISSUED_AT="$(now_s)"
	set_state T "pmset sleepnow issued"
	xmut 30 pmset sleepnow; rc=$?
	{ echo "$(epoch_to_utc "$SLEEP_ISSUED_AT") pmset sleepnow -> rc=$rc"; printf '%s\n' "$XMUT_OUT" | sed 's/^/    /'; } >> "$RUN_DIR/sleep-attempts.txt"
	if [ "$rc" -eq 0 ] && confirm_sleep "$prev"; then echo "    outcome: sleep produced by pmset sleepnow" >> "$RUN_DIR/sleep-attempts.txt"; return 0; fi
	echo "    outcome: no gap and no new 'Entering Sleep' line within ${SLEEP_CONFIRM_SECS}s (or rc != 0)" >> "$RUN_DIR/sleep-attempts.txt"

	if abort_requested; then return 2; fi
	SLEEP_ISSUED_AT="$(now_s)"
	set_state T "osascript System Events sleep issued"
	xmut 30 osascript -e 'tell application "System Events" to sleep'; rc=$?
	{ echo "$(epoch_to_utc "$SLEEP_ISSUED_AT") osascript -e 'tell application \"System Events\" to sleep' -> rc=$rc"; printf '%s\n' "$XMUT_OUT" | sed 's/^/    /'; } >> "$RUN_DIR/sleep-attempts.txt"
	if [ "$rc" -eq 0 ] && confirm_sleep "$prev"; then echo "    outcome: sleep produced by osascript" >> "$RUN_DIR/sleep-attempts.txt"; return 0; fi
	echo "    outcome: no gap and no new 'Entering Sleep' line within ${SLEEP_CONFIRM_SECS}s (or rc != 0)" >> "$RUN_DIR/sleep-attempts.txt"
	echo "    arm T: sleep not produced" >> "$RUN_DIR/sleep-attempts.txt"
	SLEEP_ISSUED_AT=0
	return 1
}

do_arm_t() {
	arm_begin T-wait "waiting for a renewal of $TRACK_ID on $TRACK_NODE, at most ${T_WAIT_CAP}s"
	FAST_CERTS_UNTIL=$(( $(now_s) + T_WAIT_CAP + 60 ))
	observe pred_t_wait; local rc=$?
	if [ "$rc" -eq 2 ]; then arm_end "ABORT"; return 2; fi
	if [ "$RENEWALS_IN_PHASE" -ge 1 ]; then
		arm_end "renewal seen (issuance $(epoch_to_utc "$LAST_RENEWAL_TW")); the sleep request follows ${SLEEP_AFTER_RENEWAL}s after it"
	else
		arm_end "no renewal seen within ${T_WAIT_CAP}s; the sleep request follows anyway and the analysis uses measured times"
	fi

	arm_begin T "treatment: forced host sleep, then the adaptive awake window"
	force_sleep; rc=$?
	if [ "$rc" -eq 2 ]; then arm_end "ABORT before the sleep request"; return 2; fi
	if [ "$rc" -ne 0 ]; then
		SLEEP_NOT_PRODUCED=1
		set_state T "sleep not produced"
		collect_logs T
		arm_end "sleep not produced (sleep-attempts.txt holds both outputs)"
		return 1
	fi
	set_state T "sleep produced; observing until ${T_MIN_AWAKE}s awake and $T_MIN_RENEWALS renewals since the last gap >= ${LONG_GAP}s, cap ${T_CAP_AWAKE}s awake"
	PHASE_AWAKE=0
	observe pred_t_done; rc=$?
	dump_pmset_window "after arm T"
	collect_logs T
	if [ "$rc" -eq 2 ]; then arm_end "ABORT during the awake window; first wake $( [ "$FIRST_WAKE" -gt 0 ] && epoch_to_utc "$FIRST_WAKE" )"; return 2; fi
	arm_end "$T_END_REASON; first wake $(epoch_to_utc "$FIRST_WAKE"); gaps so far $GAPS"
	return 0
}

# ------------------------------------------------------------------------------------------------
# Arm P4
# ------------------------------------------------------------------------------------------------
pred_p4() { [ "$RENEWALS_IN_ARM" -ge "$P4_RENEWALS" ] || [ "$ARM_AWAKE" -ge "$P4_CAP_AWAKE" ]; }
do_arm_p4() {
	arm_begin P4 "restart remedy at the override's lifetime: rollout restart ds/ztunnel, then $P4_RENEWALS renewals or ${P4_CAP_AWAKE}s awake"
	if ! xmut 45 kubectl --context "$KCTX" -n "$ISTIO_NS" rollout restart ds/ztunnel; then arm_end "rollout restart failed"; return 1; fi
	xlong 300 "$RUN_DIR/rollout.p4.txt" kubectl --context "$KCTX" -n "$ISTIO_NS" rollout status ds/ztunnel --timeout=240s || log "WARN P4: rollout status did not report completion"
	record_anchor "p4: rollout restart ds/ztunnel"
	ARM_AWAKE=0
	FAST_CERTS_UNTIL=$(( $(now_s) + P4_CAP_AWAKE ))
	observe pred_p4; local rc=$?
	collect_logs P4
	if [ "$rc" -eq 2 ]; then arm_end "ABORT"; return 2; fi
	arm_end "renewals seen after the restart: $RENEWALS_IN_ARM"
	return 0
}

# ------------------------------------------------------------------------------------------------
# pmset's log for the run window, verbatim and by kind
# ------------------------------------------------------------------------------------------------
RUN_START=0
dump_pmset_window() { # dump_pmset_window <label>
	local from; from="$(epoch_to_pmset_local "$RUN_START")"
	dry && from="$(date -u -r "$RUN_START" "+%Y-%m-%d %H:%M:%S")"
	xread 45 pmset -g log > "$RUN_DIR/.pmset-log.tmp" 2>/dev/null
	awk -v from="$from" '/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / { keep = (substr($0, 1, 19) >= from) } keep' "$RUN_DIR/.pmset-log.tmp" > "$RUN_DIR/host-sleep-window-raw.txt"
	{
		echo "# pmset -g log, read $(stamp) ($1). Window: from the run's start, $from local ($(epoch_to_utc "$RUN_START")), to the read."
		echo "# pmset stamps are local time with their offset; nothing here is edited. The whole window, every kind, is in host-sleep-window-raw.txt."
		echo
		echo "## Sleep, DarkWake and Wake lines, verbatim, in order"
		awk '{ k = $4 } k == "Sleep" || k == "DarkWake" || k == "Wake"' "$RUN_DIR/host-sleep-window-raw.txt"
		echo
		echo "## Assertions lines by kind: count, process, action, assertion type"
		awk '$4 == "Assertions" { p = $6; sub(/^[0-9]+\(/, "", p); sub(/\)$/, "", p); c[p " " $7 " " $8]++ } END { for (k in c) printf "%7d  %s\n", c[k], k }' "$RUN_DIR/host-sleep-window-raw.txt" | sort -rn
		echo
		echo "## Assertions lines, verbatim, within two minutes before each Sleep line"
		awk '
			function secs(d, t,   a, b) { split(d, a, "-"); split(t, b, ":"); return (a[3] * 86400) + (b[1] * 3600) + (b[2] * 60) + b[3] }
			$4 == "Assertions" { n++; line[n] = $0; at[n] = secs($1, $2) }
			$4 == "Sleep"      { s = secs($1, $2); print "-- before: " $0; for (i = 1; i <= n; i++) if (at[i] <= s && at[i] >= s - 120) print line[i] }
		' "$RUN_DIR/host-sleep-window-raw.txt"
	} > "$RUN_DIR/host-sleep.txt"
	rm -f "$RUN_DIR/.pmset-log.tmp"
	log "pmset window written ($1): $(grep -c . "$RUN_DIR/host-sleep-window-raw.txt") raw lines"
	tick
}

# ------------------------------------------------------------------------------------------------
# Restore: the committed values alone, read back. Shared by `run`, the trap and `restore`.
# ------------------------------------------------------------------------------------------------
IN_RESTORE=0
do_restore() {
	IN_RESTORE=1
	set_state Restore "helm upgrade with $VALUES_REL alone, then the readbacks"
	ARM_START="$(now_s)"; ARM_AWAKE=0; RENEWALS_IN_ARM=0
	rm -f "$RUN_DIR/RESTORE-VERIFIED"
	# Written first and removed only after every readback has passed, so a restore that is cut short
	# at any point (a signal, kill -9, a power loss) still leaves a marker saying it was not read back.
	atomic_write "$RUN_DIR/RESTORE-FAILED" "$(stamp) restore in progress, not read back yet. If no driver is running, it was interrupted: run driver.sh restore $RUN_DIR"
	read_makefile_pins || { atomic_write "$RUN_DIR/RESTORE-FAILED" "$(stamp) Makefile pins not read"; return 1; }
	local rb="$RUN_DIR/restore-readback.txt" attempt=1 done_route="" ttl ttl_s
	ttl="$(committed_ttl)"; ttl_s="$(ttl_to_s "$ttl")"
	{ echo; echo "# restore at $(stamp) (DRY_RUN=$DRY_RUN)"; echo "-- helm history before:"; xread 30 helm --kube-context "$KCTX" history ztunnel -n "$ISTIO_NS" | sed 's/^/   /'; } >> "$rb" 2>&1
	tick

	while [ "$attempt" -le "$RESTORE_ATTEMPTS" ]; do
		if helm_upgrade "$RUN_DIR/helm-upgrade.restore.$attempt.txt"; then done_route="repository route (the Makefile's command), attempt $attempt"; break; fi
		log "restore attempt $attempt through the repository failed; trying the chart archive pulled at Setup"
		if helm_upgrade_from_tgz "$RUN_DIR/helm-upgrade.restore.$attempt.tgz.txt"; then done_route="chart archive route, attempt $attempt"; break; fi
		attempt=$((attempt + 1))
		[ "$attempt" -le "$RESTORE_ATTEMPTS" ] && { log "waiting 60 s before restore attempt $attempt"; nap 60; tick; }
	done
	if [ -z "$done_route" ]; then
		echo "-- helm upgrade: every attempt failed ($RESTORE_ATTEMPTS)" >> "$rb"
		atomic_write "$RUN_DIR/RESTORE-FAILED" "$(stamp) helm upgrade with the committed values failed $RESTORE_ATTEMPTS times; the cluster may still carry the override. Run: driver.sh restore $RUN_DIR"
		set_state Restore "FAILED: helm upgrade"
		return 1
	fi
	echo "-- helm upgrade: $done_route" >> "$rb"
	xlong 300 "$RUN_DIR/rollout.restore.txt" kubectl --context "$KCTX" -n "$ISTIO_NS" rollout status ds/ztunnel --timeout=240s
	record_anchor "restore: helm upgrade with the committed values"

	local why=""
	# a. helm values
	xread 30 helm --kube-context "$KCTX" get values ztunnel -n "$ISTIO_NS" -o json > "$RUN_DIR/.helm-values.json" 2>/dev/null; tick
	{ echo "-- helm get values against $VALUES_REL:"; values_equal "$VALUES_FILE" "$RUN_DIR/.helm-values.json" | sed 's/^/   /'; } >> "$rb" 2>&1
	values_equal "$VALUES_FILE" "$RUN_DIR/.helm-values.json" >/dev/null 2>&1 || why="$why helm values differ from the committed file;"
	rm -f "$RUN_DIR/.helm-values.json"
	# b. DaemonSet env
	local env; env="$(ds_env)"; tick
	{ echo "-- DaemonSet env:"; printf '%s\n' "$env" | sed 's/^/   /'; } >> "$rb"
	printf '%s\n' "$env" | grep -qx "SECRET_TTL=$ttl" || why="$why DaemonSet env lacks SECRET_TTL=$ttl;"
	rust_log_standard "$env" || why="$why DaemonSet env RUST_LOG is not the standard one (read: $(rust_log_of "$env" | tr '\n' ' '));"
	local std_rl=""
	if [ -s "$RUN_DIR/ds-env.standard.txt" ]; then
		std_rl="$(rust_log_of "$(cat "$RUN_DIR/ds-env.standard.txt")")"
		if printf '%s\n' "$env" | sort | diff - "$RUN_DIR/ds-env.standard.txt" > "$RUN_DIR/.ds-env.diff" 2>&1; then
			echo "-- DaemonSet env against ds-env.standard.txt (captured at this run's preflight): identical, $(grep -c . "$RUN_DIR/ds-env.standard.txt") entries" >> "$rb"
		else
			{ echo "-- DaemonSet env against ds-env.standard.txt: DIFFERS"; sed 's/^/   /' "$RUN_DIR/.ds-env.diff"; } >> "$rb"
			why="$why DaemonSet env differs from the one captured at preflight;"
		fi
		rm -f "$RUN_DIR/.ds-env.diff"
	else
		echo "-- no ds-env.standard.txt in this run directory (a standalone restore without a preflight): the env is judged by SECRET_TTL and a single RUST_LOG without an identity or debug directive" >> "$rb"
	fi
	# c. every running ztunnel pod
	local penv; penv="$(pods_env)"; tick
	{ echo "-- ztunnel pods' env (SECRET_TTL and RUST_LOG only):"; printf '%s\n' "$penv" | awk '{ n = split($2, e, ";"); s = ""; for (i = 1; i <= n; i++) if (e[i] ~ /^(SECRET_TTL|RUST_LOG)=/) s = s " " e[i]; print "   " $1 s }'; } >> "$rb"
	[ "$(printf '%s\n' "$penv" | grep -c .)" -ge 2 ] || why="$why fewer than two ztunnel pods read;"
	printf '%s\n' "$penv" | grep . | grep -v "SECRET_TTL=$ttl;" | grep -q . && why="$why a ztunnel pod lacks SECRET_TTL=$ttl;"
	printf '%s\n' "$penv" | grep -qE 'RUST_LOG=[^;]*(identity|debug|trace)' && why="$why a ztunnel pod still has the override's RUST_LOG;"
	if [ -n "$std_rl" ]; then printf '%s\n' "$penv" | grep . | grep -v "RUST_LOG=$std_rl;" | grep -q . && why="$why a ztunnel pod's RUST_LOG is not the standard '$std_rl';"; fi
	# d. rollout complete
	local st d u r a g og; st="$(ds_status)"; tick
	read -r d u r a g og <<< "$st"
	echo "-- DaemonSet status (desired updated ready available generation observedGeneration): $st" >> "$rb"
	if [ -z "${og:-}" ] || [ "$d" != "$u" ] || [ "$d" != "$r" ] || [ "$d" != "$a" ] || [ "$g" != "$og" ]; then why="$why rollout not complete ($st);"; fi
	# e. leaves
	if [ -n "$ttl_s" ] && wait_leaves $((ttl_s + BACKDATE_S)) "$rb" 300; then :; else why="$why leaves not read back at ${ttl} (+${BACKDATE_S}s) with VALID CERT true;"; fi
	# f. the log filter, recorded; only an explicit debug directive fails it
	local filt; filt="$(xread 30 istioctl --context "$KCTX" ztunnel-config log)"; tick
	{ echo "-- istioctl ztunnel-config log (a read):"; printf '%s\n' "$filt" | sed 's/^/   /'; } >> "$rb"
	case "$filt" in *"identity=debug"*) why="$why the log filter still shows identity=debug;" ;; esac
	# g. the probe pod this driver created
	if [ -f "$RUN_DIR/PROBE-POD-CREATED" ]; then
		xlong 120 "$RUN_DIR/probe-pod-delete.txt" kubectl --context "$KCTX" -n "$LAB_NS" delete pod "$PROBE_POD" --ignore-not-found --wait=true
		local phase; phase="$(xread 20 kubectl --context "$KCTX" -n "$LAB_NS" get pod "$PROBE_POD" --ignore-not-found -o 'jsonpath={.status.phase}')"
		echo "-- probe pod $LAB_NS/$PROBE_POD after delete: '${phase}' (empty means absent)" >> "$rb"
		[ -z "$phase" ] || why="$why the probe pod is still present;"
	fi
	# h. helm history
	{ echo "-- helm history after:"; xread 30 helm --kube-context "$KCTX" history ztunnel -n "$ISTIO_NS" | sed 's/^/   /'; } >> "$rb" 2>&1
	tick
	xread 30 helm --kube-context "$KCTX" history ztunnel -n "$ISTIO_NS" > "$RUN_DIR/helm-history.after.txt" 2>&1
	[ -s "$RUN_DIR/helm-history.after.txt" ] || why="$why helm history not read;"

	if [ -n "$why" ]; then
		echo "-- RESULT: NOT verified:$why" >> "$rb"
		atomic_write "$RUN_DIR/RESTORE-FAILED" "$(stamp)$why see restore-readback.txt. Run: driver.sh restore $RUN_DIR"
		set_state Restore "FAILED:$why"
		return 1
	fi
	echo "-- RESULT: verified at $(stamp): $done_route; the release values equal $VALUES_REL alone; SECRET_TTL=$ttl and the standard RUST_LOG=$(rust_log_of "$env") on the DaemonSet and on every ztunnel pod$( [ -n "$std_rl" ] && printf ', the whole DaemonSet env identical to the one captured at preflight'); rollout complete; every leaf held by either node's ztunnel at $((ttl_s + BACKDATE_S))s with VALID CERT true, $TRACK_ID among them on $TRACK_NODE" >> "$rb"
	rm -f "$RUN_DIR/RESTORE-FAILED"
	atomic_write "$RUN_DIR/RESTORE-VERIFIED" "$(stamp) $done_route; read back: helm values, DaemonSet env, pod env, rollout, every leaf on both nodes' ztunnels at $((ttl_s + BACKDATE_S))s VALID CERT true, helm history. See restore-readback.txt"
	collect_logs Restore
	write_environment "after the restore"
	arm_end "restore read back"
	IN_RESTORE=0
	return 0
}

# ------------------------------------------------------------------------------------------------
# Trap
# ------------------------------------------------------------------------------------------------
TRAP_RAN=0
XLONG_PID=""
on_exit() {
	local rc=$?
	trap - EXIT
	if [ -n "$XLONG_PID" ] && kill -0 "$XLONG_PID" 2>/dev/null; then
		# A helm upgrade killed half way leaves the release pending and blocks the next upgrade, so
		# the command that is running is left to end (helm's own --wait timeout bounds it).
		trap '' INT TERM
		log "exit path: waiting for the running command (pid $XLONG_PID) to end before anything else"
		wait "$XLONG_PID" 2>/dev/null
		XLONG_PID=""
	fi
	if [ "$TRAP_RAN" -eq 0 ] && [ -f "$RUN_DIR/OVERRIDE-APPLIED" ] && [ ! -f "$RUN_DIR/RESTORE-VERIFIED" ]; then
		TRAP_RAN=1
		trap '' INT TERM
		log "exit path (rc=$rc) with the override applied and no verified restore: restoring now; INT and TERM are ignored until it ends"
		if do_restore; then log "trap: restore read back"; else log "trap: restore NOT read back; RESTORE-FAILED holds the reason"; rc=50; fi
	fi
	rm -f "$RUN_DIR/driver.pid" "$ERRTMP"
	[ -f "$RUN_DIR/STATE" ] && log "driver exits rc=$rc"
	exit "$rc"
}

# The standalone restore's exit path: it does not start the restore over (whoever interrupted it
# asked it to stop); it lets a running helm end and leaves RESTORE-FAILED as do_restore wrote it.
on_exit_restore() {
	local rc=$?
	trap - EXIT
	if [ -n "$XLONG_PID" ] && kill -0 "$XLONG_PID" 2>/dev/null; then
		trap '' INT TERM
		log "exit path: waiting for the running command (pid $XLONG_PID) to end"
		wait "$XLONG_PID" 2>/dev/null
	fi
	rm -f "$ERRTMP" "$RUN_DIR/driver.pid"
	[ -f "$RUN_DIR/RESTORE-VERIFIED" ] || log "standalone restore ends rc=$rc WITHOUT a verified restore: $(cat "$RUN_DIR/RESTORE-FAILED" 2>/dev/null)"
	exit "$rc"
}

# ------------------------------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------------------------------
dry_init() {
	dry || return 0
	mkdir -p "$DRY_DIR"
	[ -f "$DRY_DIR/now" ] || printf '%s\n' "${DRY_START_EPOCH:-1790000000}" > "$DRY_DIR/now"
	: >> "$DRY_DIR/gaps-applied"; : >> "$DRY_DIR/gap-pending"; : >> "$DRY_DIR/commands.log"
	sim init >/dev/null
}

driver_alive() {
	[ -f "$RUN_DIR/driver.pid" ] || return 1
	local p; read -r p < "$RUN_DIR/driver.pid"
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

cmd_preflight() {
	dry_init
	cd "$REPO_ROOT" || exit 64
	if do_preflight; then write_environment "preflight"; exit 0; fi
	exit 60
}

cmd_run() {
	if driver_alive; then echo "a driver is already running on $RUN_DIR (pid $(cat "$RUN_DIR/driver.pid"))" >&2; exit 64; fi
	if [ -f "$RUN_DIR/STATE" ]; then echo "$RUN_DIR already holds a run (STATE exists); use a new run directory" >&2; exit 64; fi
	dry_init
	cd "$REPO_ROOT" || exit 64
	echo $$ > "$RUN_DIR/driver.pid"
	init_csvs
	RUN_START="$(now_s)"
	trap on_exit EXIT
	trap 'log "signal INT"; exit 130' INT
	trap 'log "signal TERM"; exit 143' TERM
	set_state Preflight "run started, pid $$"
	log "driver $SELF; run dir $RUN_DIR; repository root $REPO_ROOT; DRY_RUN=$DRY_RUN$(dry && printf ' scenario %s' "$DRY_SCENARIO")"
	log "curl flags of the probe: $PROBE_CURL_FLAGS"
	log "configuration: P1_GATE=$P1_GATE P1_MAX_RESIDUAL=${P1_MAX_RESIDUAL}s P1_MIN_RENEWALS=$P1_MIN_RENEWALS ARM_C_SECS=$ARM_C_SECS T_WAIT_CAP=$T_WAIT_CAP SLEEP_AFTER_RENEWAL=$SLEEP_AFTER_RENEWAL SLEEP_CONFIRM_SECS=$SLEEP_CONFIRM_SECS T_MIN_AWAKE=$T_MIN_AWAKE T_MIN_RENEWALS=$T_MIN_RENEWALS T_CAP_AWAKE=$T_CAP_AWAKE LONG_GAP=$LONG_GAP GAP_THRESHOLD=$GAP_THRESHOLD P4_RENEWALS=$P4_RENEWALS P4_CAP_AWAKE=$P4_CAP_AWAKE RESTORE_ATTEMPTS=$RESTORE_ATTEMPTS OVERRIDE_TTL=$OVERRIDE_TTL OVERRIDE_RUST_LOG=$OVERRIDE_RUST_LOG TRACK_ID=$TRACK_ID TRACK_NODE=$TRACK_NODE"
	[ -f "$RUN_DIR/rulings.txt" ] && { log "rulings.txt, as found in the run directory at the start:"; sed 's/^/    | /' "$RUN_DIR/rulings.txt" >> "$RUN_DIR/driver.log"; }
	if ! do_preflight >/dev/null; then set_state Done "preflight failed; nothing applied"; exit 60; fi
	tick

	local result=0 rc
	if do_setup; then :; else result=40; fi
	if [ "$result" -eq 0 ] && ! abort_requested; then do_arm_c; fi
	if [ "$result" -eq 0 ] && ! abort_requested; then p1_gate || result=30; fi
	if [ "$result" -eq 0 ] && ! abort_requested; then
		do_arm_t; rc=$?
		[ "$rc" -eq 1 ] && result=20
	fi
	if { [ "$result" -eq 0 ] || [ "$result" -eq 20 ]; } && ! abort_requested; then do_arm_p4; fi
	if abort_requested && { [ "$result" -eq 0 ] || [ "$result" -eq 20 ]; }; then result=10; fi
	dump_pmset_window "before the restore"
	if ! do_restore; then result=50; fi
	dump_pmset_window "end of the run"
	python3 "$DERIVE" "$RUN_DIR" --track-id "$TRACK_ID" --track-node "$TRACK_NODE" > "$RUN_DIR/derive.out" 2>&1 || log "derive returned non-zero at the end of the run (derive.out); the records are unaffected"
	case "$result" in
		0)  set_state Done "all arms ran; restore read back" ;;
		10) set_state Done "ABORT honoured; restore read back" ;;
		20) set_state Done "sleep not produced; P4 ran; restore read back" ;;
		30) set_state Done "P1 gate failed after arm C; arm T skipped; restore read back" ;;
		40) set_state Done "Setup failed; restore read back" ;;
		50) set_state Done "RESTORE NOT READ BACK: see RESTORE-FAILED" ;;
	esac
	exit "$result"
}

cmd_restore() {
	if driver_alive && [ "${FORCE:-0}" != "1" ]; then
		echo "a driver is running on $RUN_DIR (pid $(cat "$RUN_DIR/driver.pid")). To stop it: touch $RUN_DIR/ABORT (it restores by itself). FORCE=1 overrides." >&2
		exit 64
	fi
	dry_init
	cd "$REPO_ROOT" || exit 64
	init_csvs
	echo $$ > "$RUN_DIR/driver.pid"
	trap on_exit_restore EXIT
	trap 'log "signal INT during the standalone restore"; exit 130' INT
	trap 'log "signal TERM during the standalone restore"; exit 143' TERM
	RUN_START="$(now_s)"; tick
	log "standalone restore requested"
	if do_restore; then echo "restore read back: $(cat "$RUN_DIR/RESTORE-VERIFIED")"; exit 0; fi
	echo "restore NOT read back: $(cat "$RUN_DIR/RESTORE-FAILED" 2>/dev/null)" >&2
	exit 50
}

cmd_status() {
	echo "run dir : $RUN_DIR"
	echo "STATE   : $(cat "$RUN_DIR/STATE" 2>/dev/null || echo none)"
	if driver_alive; then echo "driver  : running, pid $(cat "$RUN_DIR/driver.pid")"; else echo "driver  : not running"; fi
	local m
	for m in OVERRIDE-APPLIED RESTORE-VERIFIED RESTORE-FAILED ABORT PROBE-POD-CREATED; do
		if [ -f "$RUN_DIR/$m" ]; then echo "$m: $(tr '\n' ' ' < "$RUN_DIR/$m")"; else echo "$m: absent"; fi
	done
	if [ -f "$RUN_DIR/progress.env" ]; then echo "-- progress"; sed 's/^/   /' "$RUN_DIR/progress.env"; fi
	echo "-- rows"
	for m in clock.csv certs.csv csr-counters.csv probe.csv gaps.csv renewal-events.csv arms.csv; do
		[ -f "$RUN_DIR/$m" ] && printf '   %-20s %s\n' "$m" "$(grep -vc '^#' "$RUN_DIR/$m")"
	done
	if [ -f "$RUN_DIR/gaps.csv" ]; then echo "-- gaps"; sed 's/^/   /' "$RUN_DIR/gaps.csv"; fi
	if [ -f "$RUN_DIR/certs.csv" ]; then echo "-- last reading of $TRACK_ID on $TRACK_NODE"; grep ",$TRACK_NODE,$TRACK_ID,Leaf," "$RUN_DIR/certs.csv" | tail -1 | sed 's/^/   /'; fi
	if [ -f "$RUN_DIR/driver.log" ]; then echo "-- driver.log, last 12 lines"; tail -12 "$RUN_DIR/driver.log" | sed 's/^/   /'; fi
	exit 0
}

# test/run-tests.sh sources this file with DRIVER_SOURCE_ONLY=1 to call single functions for real
# (the bounded runner, the stamp and TTL parsers, the values comparison, the pmset window).
if [ "${DRIVER_SOURCE_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

case "$CMD" in
	preflight) cmd_preflight ;;
	run)       cmd_run ;;
	restore)   cmd_restore ;;
	status)    cmd_status ;;
esac
