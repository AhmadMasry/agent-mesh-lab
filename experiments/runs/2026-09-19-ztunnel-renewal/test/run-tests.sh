#!/bin/bash
# Offline checks for driver.sh and derive-renewals.py. Nothing here touches a cluster, Docker, or
# the host's power state: every scenario runs the driver with DRY_RUN=1, in which xread / xmut /
# xlong never execute a command (they log it and return test/sim.py's canned reading) and the clock
# is a file the fixtures step forward.
#
#   test/run-tests.sh <work dir>        (the work dir is wiped and refilled; use a scratch directory)
#
# Prints one PASS/FAIL line per assertion and exits 1 if any failed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DRV="$HERE/../driver.sh"; DERIVE="$HERE/../derive-renewals.py"
W="${1:?work dir}"; rm -rf "$W"; mkdir -p "$W"; W="$(cd "$W" && pwd -P)"
FAILS=0
ok()   { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }   # check <text> <shell test>

wait_state() { # wait_state <run dir> <arm> <max seconds>: poll STATE until arm=<arm>
	local i=0
	while [ "$i" -lt $(( $3 * 20 )) ]; do
		grep -q "^arm=$2 " "$1/STATE" 2>/dev/null && return 0
		sleep 0.05; i=$((i + 1))
	done
	return 1
}
cmds()  { grep -c "$2" "$1/.dry/commands.log"; }
exitof() { cat "$1/exit" 2>/dev/null; }

echo "== static"
check "bash -n driver.sh under $(/bin/bash --version | head -1 | sed 's/.*version \([^ ]*\).*/\1/')" "/bin/bash -n '$DRV'"
check "bash -n run-tests.sh" "/bin/bash -n '$HERE/run-tests.sh'"
check "py_compile derive-renewals.py, sim.py, make-derive-fixture.py" "python3 -m py_compile '$DERIVE' '$HERE/sim.py' '$HERE/make-derive-fixture.py'"
if command -v shellcheck >/dev/null 2>&1; then check "shellcheck driver.sh" "shellcheck -s bash '$DRV'"; else echo "SKIP  shellcheck is not installed on this host"; fi
check "no direct call of a cluster or power tool outside xread/xmut/xlong" \
	"! grep -nE '^[^#]*(^|[;&|(]|\\\$\\()[[:space:]]*(kubectl|helm|istioctl|docker|pmset|osascript|kind|make)[[:space:]]' '$DRV' | grep -vE 'xread|xmut|xlong|_blocked|command -v'"
check "no keep-awake, no sudo, no power-setting change, no make target in the driver's code" \
	"! grep -vE '^[[:space:]]*#' '$DRV' | grep -nE 'caffeinate|sudo |pmset (-[abcu]|schedule|repeat|relative)|[[:space:]]make (step|cluster|teardown)'"

# ---- scenarios, run in parallel where they do not need steering
run_bg() { # run_bg <name> [VAR=value ...]
	local name="$1"; shift
	mkdir -p "$W/$name"
	( cd "$HERE/.." && env DRY_RUN=1 DRY_SCENARIO="$name" "$@" /bin/bash "$DRV" run "$W/$name" > "$W/$name/driver.out" 2>&1; echo $? > "$W/$name/exit" ) &
}
echo "== scenarios started: normal cap nosleep osascript osascript-late p1fail abort-presleep (parallel), then abort-c, trap, restorefail (steered)"
run_bg normal
run_bg cap T_CAP_AWAKE=5400
run_bg nosleep
run_bg osascript
run_bg osascript-late
run_bg p1fail
run_bg abort-presleep DRY_ABORT_AT=presleep

# steered: ABORT during arm C
run_bg abort-c DRY_REAL_NAP=0.02
if wait_state "$W/abort-c" C 120; then : > "$W/abort-c/ABORT"; else bad "abort-c: arm C never reached"; fi
# steered: TERM during arm C
mkdir -p "$W/trap"
( cd "$HERE/.." && DRY_RUN=1 DRY_SCENARIO=trap DRY_REAL_NAP=0.02 /bin/bash "$DRV" run "$W/trap" > "$W/trap/driver.out" 2>&1 & echo $! > "$W/trap/bgpid"; wait $!; echo $? > "$W/trap/exit" ) &
if wait_state "$W/trap" C 120; then sleep 0.5; kill -TERM "$(cat "$W/trap/driver.pid")"; else bad "trap: arm C never reached"; fi
# steered: the restore does not read back (the simulator leaves RUST_LOG on the workload)
run_bg restorefail DRY_REAL_NAP=0.02
if wait_state "$W/restorefail" C 120; then : > "$W/restorefail/ABORT"; else bad "restorefail: arm C never reached"; fi
wait

for n in normal cap nosleep osascript osascript-late p1fail abort-presleep abort-c trap restorefail; do
	check "$n: no BLOCKED direct call and no unmapped command in DRY_RUN" "! grep -qE 'BLOCKED|UNMAPPED' '$W/$n/driver.log'"
done

echo "== normal: 3 h gap, 40 s running, 1000 s gap, then awake"
R="$W/normal"
check "exit 0" "[ \"$(exitof "$R")\" = 0 ]"
check "markers: OVERRIDE-APPLIED and RESTORE-VERIFIED present, RESTORE-FAILED absent" "[ -f '$R/OVERRIDE-APPLIED' ] && [ -f '$R/RESTORE-VERIFIED' ] && [ ! -f '$R/RESTORE-FAILED' ]"
check "wake detector: two gaps recorded (10802 s, 1005 s)" "[ \"\$(tail -n +2 '$R/gaps.csv' | cut -d, -f3 | tr '\n' ' ')\" = '10802 1005 ' ]"
check "first wake set from the first gap" "grep -q 'first wake after the forced sleep' '$R/driver.log'"
check "fast sampling after a gap: clock rows 5 s apart in the first 3 min after the first wake" \
	"[ \"\$(awk -F, -v n=agent-mesh-lab-worker '\$3 == n && \$1 + 0 >= 1790012776 && \$1 + 0 < 1790012816 { c++ } END { print c }' '$R/clock.csv')\" -ge 7 ]"
check "the second gap (>= 900 s) restarted the two-renewals count" "grep -q 'the two-renewals count restarts here' '$R/driver.log'"
check "adaptive window: arm T ran past 65 min, to the second renewal at about 4 min + D (awake 12265 s)" \
	"grep -q '^T,.*,122[0-9][0-9],2,.*2 renewals of the tracked identity since the last gap' '$R/arms.csv'"
check "sleep requested once with pmset sleepnow, never with osascript" "[ \"\$(cmds '$R' 'mutate: pmset sleepnow')\" = 1 ] && [ \"\$(cmds '$R' 'mutate: osascript')\" = 0 ]"
check "pre-sleep snapshot of pmset -g assertions written" "[ -s '$R/pmset-assertions.pre-sleep.txt' ]"
check "the override sets the filter through the chart's logLevel key, never RUST_LOG under env" "grep -q '^logLevel: \"info,ztunnel::identity=debug\"' '$R/ztunnel-ttl-override.yaml' && ! grep -q 'RUST_LOG' '$R/ztunnel-ttl-override.yaml'"
check "Setup read back exactly one RUST_LOG entry with the override's value" "[ \"\$(grep -c 'RUST_LOG=info,ztunnel::identity=debug' '$R/setup-readback.txt')\" = 1 ]"
check "the restore read the whole DaemonSet env back identical to the one captured at preflight (RUST_LOG=info among it)" "grep -q 'DaemonSet env against ds-env.standard.txt (captured at this run.s preflight): identical' '$R/restore-readback.txt' && grep -qx 'RUST_LOG=info' '$R/ds-env.standard.txt'"
check "P1 gate passed" "grep -q '^gate: passed' '$R/p1-gate.txt'"
check "the log header records the effective configuration (the P1 gate's bound among it)" "grep -q 'configuration: P1_GATE=strict P1_MAX_RESIDUAL=5s' '$R/driver.log'"
check "order of the changing commands: override, probe pod, sleepnow, rollout restart, committed values, probe pod delete" \
	"[ \"\$(grep -E 'mutate:|long: helm .* upgrade|long: kubectl .* (run|delete pod) ' '$R/.dry/commands.log' | awk '{ if (\$0 ~ /override.yaml/) print \"O\"; else if (\$0 ~ / run zt-probe/) print \"P\"; else if (\$0 ~ /sleepnow/) print \"S\"; else if (\$0 ~ /rollout restart/) print \"R\"; else if (\$0 ~ /upgrade -i/) print \"C\"; else if (\$0 ~ /delete pod/) print \"D\" }' | tr -d '\n')\" = OPSRCD ]"
check "the restore's helm command carries the committed values file and no second -f" \
	"grep 'long: helm' '$R/.dry/commands.log' | tail -1 | grep -q -- '-f deploy/step-2-ambient-agw/ztunnel-values.yaml --wait' && ! grep 'long: helm' '$R/.dry/commands.log' | tail -1 | grep -q override"
check "probe header records curl's flags with --retry 0" "head -1 '$R/probe.csv' | grep -q -- '--retry 0'"
check "derive: every measured residual within 0.001 s of 0 against the simulator's known D (11800 s)" \
	"[ \"\$(awk -F, 'NR > 1 && \$20 != \"\" { n++; if (\$20 > 0.001 || \$20 < -0.001) b++ } END { print n \":\" b + 0 }' '$R/renewals.csv')\" = '24:0' ]"
check "derive: post-wake renewals carry D = 11800 s" "[ \"\$(awk -F, 'NR > 1 && \$1 == \"T\" && \$16 == \"11800.000\"' '$R/renewals.csv' | wc -l | tr -d ' ')\" = 4 ]"
# the invariant, not a number: in every window (each arm, and the whole run) istiod's counter delta equals the serial changes derived for the same window
check "derive: istiod's CSR-counter delta equals the serial changes counted in the same window, for every arm and for the whole run (>= 20)" \
	"[ \"\$(sed -n 's/.*(delta \\([0-9]*\\));.*serial changes with t_w in the window \\([0-9]*\\);.*/\\1 \\2/p' '$R/summary.txt' | awk '\$1 != \$2 { bad++ } { n++; if (\$1 > max) max = \$1 } END { print n \":\" bad + 0 \":\" (max >= 20) }')\" = '5:0:1' ]"
check "derive: D grew by the frozen time across each gap (10800 s, 1000 s)" "[ \"\$(grep -c 'D grew 10800.000s\|D grew 1000.000s' '$R/summary.txt')\" = 4 ]"
check "derive: the host's own sleep account across each gap is in gaps-d.csv (10800 s, 1000 s)" "[ \"\$(tail -n +2 '$R/gaps-d.csv' | cut -d, -f12 | sort -u | tr '\n' ' ')\" = '1000.000 10800.000 ' ]"
check "status subcommand prints the state" "/bin/bash '$DRV' status '$R' | grep -q 'arm=Done'"
( cd "$HERE/.." && DRY_RUN=1 /bin/bash "$DRV" run "$R" > "$W/rerun.out" 2>&1 ); check "a second run on a used run directory is refused (exit 64)" "[ $? = 64 ]"

echo "== cap: the second renewal would come after the cap (T_CAP_AWAKE=5400 for the test)"
R="$W/cap"
check "exit 0" "[ \"$(exitof "$R")\" = 0 ]"
check "arm T ended with 'cap reached'" "grep -q '^T,.*cap reached' '$R/arms.csv'"
check "P4 and Restore still ran; RESTORE-VERIFIED" "grep -q '^P4,' '$R/arms.csv' && [ -f '$R/RESTORE-VERIFIED' ]"

echo "== nosleep: neither request produces a sleep"
R="$W/nosleep"
check "exit 20" "[ \"$(exitof "$R")\" = 20 ]"
check "both requests made, in order, and both outputs recorded" "[ \"\$(cmds '$R' 'mutate: pmset sleepnow')\" = 1 ] && [ \"\$(cmds '$R' 'mutate: osascript')\" = 1 ] && grep -q 'pmset sleepnow -> rc=0' '$R/sleep-attempts.txt' && grep -q 'osascript .* -> rc=0' '$R/sleep-attempts.txt'"
check "arm marked 'sleep not produced'" "grep -q 'arm T: sleep not produced' '$R/sleep-attempts.txt' && grep -q '^T,.*sleep not produced' '$R/arms.csv'"
check "no gap recorded" "[ \"\$(tail -n +2 '$R/gaps.csv' | wc -l | tr -d ' ')\" = 0 ]"
check "P4 ran, then the restore; RESTORE-VERIFIED" "grep -q '^P4,' '$R/arms.csv' && [ -f '$R/RESTORE-VERIFIED' ]"

echo "== osascript: pmset sleepnow exits 1, the osascript request sleeps the host 20 min"
R="$W/osascript"
check "exit 0" "[ \"$(exitof "$R")\" = 0 ]"
check "sleepnow rc=1 recorded, then osascript produced the sleep" "grep -q 'pmset sleepnow -> rc=1' '$R/sleep-attempts.txt' && grep -q 'outcome: sleep produced by osascript' '$R/sleep-attempts.txt'"
check "a non-zero exit of pmset sleepnow sends the osascript request at once (same stamp), as the design says" "[ \"\$(awk -F, '/sleepnow issued/ { a = \$1 } /osascript System Events sleep issued/ { b = \$1 } END { print (b - a) }' '$R/state-history.csv')\" -lt 5 ]"
check "arm T ended on the 65-minute condition (awake 39xx s) with renewals >= 2" "grep -qE '^T,.*,39[0-9][0-9],[0-9]+,39[0-9][0-9]s awake' '$R/arms.csv'"

echo "== osascript-late: pmset sleepnow exits 0 without effect; after 60 s the osascript request sleeps the host 20 min"
R="$W/osascript-late"
check "exit 0" "[ \"$(exitof "$R")\" = 0 ]"
check "60 s without a gap or a new pmset line, then osascript produced the sleep" "grep -q 'pmset sleepnow -> rc=0' '$R/sleep-attempts.txt' && grep -q 'no gap and no new' '$R/sleep-attempts.txt' && grep -q 'outcome: sleep produced by osascript' '$R/sleep-attempts.txt'"
check "SLEEP_ISSUED_AT names the request that produced the sleep (the osascript one, 60+ s after the pmset one)" \
	"[ \"\$(awk -F, '/sleepnow issued/ { a = \$1 } /osascript System Events sleep issued/ { b = \$1 } END { print (b - a >= 60) \":\" b }' '$R/state-history.csv')\" = \"1:\$(sed -n 's/^SLEEP_ISSUED_AT=//p' '$R/progress.env')\" ]"

echo "== p1fail: the simulator renews 20 s late while awake"
R="$W/p1fail"
check "exit 30" "[ \"$(exitof "$R")\" = 30 ]"
check "gate failed on the residuals" "grep -q '^FAIL  residuals measured' '$R/p1-gate.txt'"
check "no sleep requested; RESTORE-VERIFIED" "[ \"\$(cmds '$R' 'mutate: pmset sleepnow')\" = 0 ] && [ -f '$R/RESTORE-VERIFIED' ]"

echo "== abort-presleep: ABORT appears after the wait loop and before the request"
R="$W/abort-presleep"
check "exit 10" "[ \"$(exitof "$R")\" = 10 ]"
check "no sleep requested; no P4; RESTORE-VERIFIED" "[ \"\$(cmds '$R' 'mutate: pmset sleepnow')\" = 0 ] && ! grep -q '^P4,' '$R/arms.csv' && [ -f '$R/RESTORE-VERIFIED' ]"

echo "== abort-c: ABORT during arm C"
R="$W/abort-c"
check "exit 10" "[ \"$(exitof "$R")\" = 10 ]"
check "straight to Restore: no T-wait, no sleep request, no P4; RESTORE-VERIFIED" "! grep -qE '^(T-wait|T|P4),' '$R/arms.csv' && [ \"\$(cmds '$R' 'mutate: pmset sleepnow')\" = 0 ] && [ -f '$R/RESTORE-VERIFIED' ]"

echo "== trap: TERM during arm C"
R="$W/trap"
check "exit 143" "[ \"$(exitof "$R")\" = 143 ]"
check "the exit path restored: log line, RESTORE-VERIFIED, driver.pid removed" "grep -q 'with the override applied and no verified restore: restoring now' '$R/driver.log' && [ -f '$R/RESTORE-VERIFIED' ] && [ ! -f '$R/driver.pid' ]"

echo "== restorefail: the workload still carries RUST_LOG after the helm upgrade"
R="$W/restorefail"
check "exit 50" "[ \"$(exitof "$R")\" = 50 ]"
check "RESTORE-FAILED names the reason; RESTORE-VERIFIED absent" "grep -q 'RUST_LOG' '$R/RESTORE-FAILED' && [ ! -f '$R/RESTORE-VERIFIED' ]"
check "the exit path does not claim a restore either" "grep -q 'restore NOT read back' '$R/driver.log' || grep -q 'RESTORE NOT READ BACK' '$R/STATE'"

echo "== standalone restore, twice"
R="$W/standalone"; mkdir -p "$R"
( cd "$HERE/.." && DRY_RUN=1 /bin/bash "$DRV" restore "$R" > "$R/out1" 2>&1 ); check "first restore exits 0 and writes RESTORE-VERIFIED" "[ $? = 0 ] && [ -f '$R/RESTORE-VERIFIED' ]"
( cd "$HERE/.." && DRY_RUN=1 /bin/bash "$DRV" restore "$R" > "$R/out2" 2>&1 ); check "second restore exits 0 (idempotent)" "[ $? = 0 ] && [ -f '$R/RESTORE-VERIFIED' ]"
R="$W/restorefail"
( cd "$HERE/.." && DRY_RUN=1 DRY_SCENARIO=normal /bin/bash "$DRV" restore "$R" > "$R/out-restore" 2>&1 ); check "standalone restore on the run whose restore failed: exit 0, RESTORE-VERIFIED written, RESTORE-FAILED removed" "[ $? = 0 ] && [ -f '$R/RESTORE-VERIFIED' ] && [ ! -f '$R/RESTORE-FAILED' ]"

echo "== a restore cut short by kill -9 still leaves a marker"
R="$W/restore-killed"; mkdir -p "$R"
( cd "$HERE/.." && DRY_RUN=1 DRY_REAL_NAP=3 exec /bin/bash "$DRV" restore "$R" > "$R/out" 2>&1 ) &
sleep 1; kpid="$(cat "$R/driver.pid" 2>/dev/null)"; kill -KILL "$kpid" 2>/dev/null; wait 2>/dev/null; sleep 4
check "the killed process was the driver itself and it is gone" "[ -n '$kpid' ] && ! kill -0 '$kpid' 2>/dev/null"
check "RESTORE-FAILED says 'in progress, not read back'; RESTORE-VERIFIED absent (4 s after the kill)" "grep -q 'restore in progress, not read back yet' '$R/RESTORE-FAILED' && [ ! -f '$R/RESTORE-VERIFIED' ]"
R="$W/restore-term"; mkdir -p "$R"
( cd "$HERE/.." && DRY_RUN=1 DRY_REAL_NAP=3 /bin/bash "$DRV" restore "$R" > "$R/out" 2>&1; echo $? > "$R/exit" ) &
sleep 1; kill -TERM "$(cat "$R/driver.pid" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null
check "standalone restore under TERM: exit 143, marker kept, log says it ended without a verified restore" "[ \"\$(cat '$R/exit')\" = 143 ] && [ -f '$R/RESTORE-FAILED' ] && [ ! -f '$R/RESTORE-VERIFIED' ] && grep -q 'signal TERM during the standalone restore' '$R/driver.log' && grep -q 'WITHOUT a verified restore' '$R/driver.log' && [ ! -f '$R/driver.pid' ]"
check "log lines never carry a doubled count (grep -c with a fallback)" "! grep -n -A1 'logs collected after' '$W/normal/driver.log' | grep -qE '^[0-9]+-0$'"

echo "== preflight refuses when AC sleep is not 0"
R="$W/preflight-fail"; mkdir -p "$R" "$W/fx"; cp -R "$HERE/fixtures/." "$W/fx/"
awk '/^AC Power:/ { ac = 1 } ac && $1 == "sleep" { sub(/0$/, "10") } { print }' "$HERE/fixtures/pmset-custom.txt" > "$W/fx/pmset-custom.txt"
( cd "$HERE/.." && DRY_RUN=1 FIXTURES="$W/fx" /bin/bash "$DRV" preflight "$R" > "$R/out" 2>&1 ); check "preflight exits 60 and names the AC sleep value" "[ $? = 60 ] && grep -q \"FAIL  pmset -g custom: AC sleep is '10'\" '$R/out'"
( cd "$HERE/.." && DRY_RUN=1 FIXTURES="$W/fx" /bin/bash "$DRV" run "$R" > "$R/out-run" 2>&1 ); check "run on the same fixtures exits 60 and applies nothing" "[ $? = 60 ] && [ ! -f '$R/OVERRIDE-APPLIED' ] && [ \"\$(grep -c 'long: helm' '$R/.dry/commands.log')\" = 0 ]"

echo "== derive on the hand-built fixture"
R="$W/derive-fixture"
python3 "$HERE/make-derive-fixture.py" "$R" > /dev/null && python3 "$DERIVE" "$R" > "$R/derive.out" 2>&1
check "five residuals, all 0.000, with D = 0, 0, 0, 1500, 1500" "[ \"\$(awk -F, 'NR > 1 && \$5 == \"ok\" { printf \"%s/%s \", \$16, \$20 }' '$R/renewals.csv')\" = '0.000/0.000 0.000/0.000 0.000/0.000 1500.000/0.000 1500.000/0.000 ' ]"
check "one ambiguous renewal, D_lo 1500 and D_hi 2100, no residual" "[ \"\$(awk -F, 'NR > 1 && \$5 == \"ambiguous\" { printf \"%s:%s:[%s]\", \$17, \$18, \$20 }' '$R/renewals.csv')\" = '1500.000:2100.000:[]' ]"

echo "== single functions, run for real (no cluster or power command among them; pmset -g log is a read)"
U="$W/unit"; mkdir -p "$U"
cat > "$U/unit.sh" <<UNIT
DRIVER_SOURCE_ONLY=1 . "$DRV" status "$U/run"
set +u
echo "now_hr=\$(now_hr)"
echo "iso=\$(iso_to_epoch 2026-09-19T18:26:28Z)"
echo "ttl=\$(ttl_to_s 168h)/\$(ttl_to_s 10m)/\$(ttl_to_s 600s)/\$(ttl_to_s bogus || echo rejected)"
echo "committed_ttl=\$(committed_ttl)"
echo '{"env":{"SECRET_TTL":"168h"},"profile":"ambient"}' > "$U/equal.json"
echo '{"env":{"SECRET_TTL":"10m"},"logLevel":"info,ztunnel::identity=debug","profile":"ambient"}' > "$U/override.json"
values_equal "\$VALUES_FILE" "$U/equal.json" > /dev/null; echo "values_equal_committed=\$?"
values_equal "\$VALUES_FILE" "$U/override.json" > /dev/null; echo "values_equal_override=\$?"
s=\$(date +%s); xread 2 sleep 30; echo "xread_timeout_rc=\$? elapsed=\$(( \$(date +%s) - s ))"
xread 5 sh -c 'echo reading; exit 7'; echo "xread_rc=\$?"
echo "host_slept=\$(host_slept)"
RUN_START=\$(( \$(date +%s) - 21600 )); dump_pmset_window "unit test, last six hours"
UNIT
/bin/bash "$U/unit.sh" > "$U/out" 2>&1
check "now_hr gives epoch seconds with six decimals" "grep -qE '^now_hr=[0-9]{10}\.[0-9]{6}$' '$U/out'"
check "iso_to_epoch parses istioctl's stamp (2026-09-19T18:26:28Z = 1789842388)" "grep -qx 'iso=1789842388' '$U/out'"
check "ttl_to_s: 168h, 10m, 600s parsed; anything else rejected" "grep -qx 'ttl=604800/600/600/rejected' '$U/out'"
check "committed_ttl reads 168h from the committed values file" "grep -qx 'committed_ttl=168h' '$U/out'"
check "values_equal: committed values equal (0), override values differ (1)" "grep -qx 'values_equal_committed=0' '$U/out' && grep -qx 'values_equal_override=1' '$U/out'"
check "bounded runner: a 30 s child under a 2 s bound ends with rc 143 within 5 s, and the failure is recorded" "grep -qE '^xread_timeout_rc=143 elapsed=[2-5]$' '$U/out' && grep -q 'rc=143 cmd=sleep 30' '$U/run/read-errors.log'"
check "bounded runner passes the child's exit code and output through" "grep -qx 'reading' '$U/out' && grep -qx 'xread_rc=7' '$U/out'"
check "host_slept reads a number from the host's clocks" "grep -qE '^host_slept=[0-9]+\.[0-9]{3}$' '$U/out'"
check "pmset window on the real log: sections written, Assertions counted by kind" "grep -q '^## Sleep, DarkWake and Wake lines' '$U/run/host-sleep.txt' && [ \"\$(sed -n '/^## Assertions lines by kind/,/^## Assertions lines, verbatim/p' '$U/run/host-sleep.txt' | grep -cE '^ +[0-9]+  ')\" -ge 1 ]"
# the certificate table's parser against a canned istioctl table that holds an identity without a chain
cat > "$U/unit-certs.sh" <<UNIT
DRIVER_SOURCE_ONLY=1 . "$DRV" status "$U/run-certs"
init_csvs
xread() { printf '%s\n' 'CERTIFICATE NAME     TYPE     STATUS        VALID CERT     SERIAL NUMBER     NOT AFTER     NOT BEFORE' \
  'spiffe://cluster.local/ns/lab/sa/default     Leaf     Available     true     c4a4944a8595db9631d43863f891ad4e     2026-09-19T18:26:28Z     2026-09-12T18:24:28Z' \
  'spiffe://cluster.local/ns/lab/sa/default     Root     Available     true     8a11b9ae6a8150b4780be9481f3b07f5     2036-09-09T17:53:50Z     2026-09-12T17:53:50Z' \
  'spiffe://cluster.local/ns/lab/sa/other     NA     Initializing     false     NA     NA     NA'; }
ARM=unit; sample_certs
leaves_ok 604920 > "$U/leaves.txt" 2>&1; echo "leaves_ok_rc=\$?"
UNIT
/bin/bash "$U/unit-certs.sh" > "$U/out-certs" 2>&1
check "certificate table parser: the Leaf row and the chainless identity (TYPE NA) are both recorded, the Root is not" \
	"[ \"\$(grep -c ',Leaf,Available,true,c4a4944a8595db9631d43863f891ad4e,2026-09-19T18:26:28Z,2026-09-12T18:24:28Z,0' '$U/run-certs/certs.csv')\" = 2 ] && [ \"\$(grep -c ',NA,Initializing,false,NA,NA,NA,0' '$U/run-certs/certs.csv')\" = 2 ] && ! grep -q ',Root,' '$U/run-certs/certs.csv'"
check "normal: the control-plane node holds no certificate, as in the lab, and every readback still passed" "grep -q 'no Leaf row on agent-mesh-lab-control-plane' '$W/normal/restore-readback.txt' && grep -q 'RESULT: verified' '$W/normal/restore-readback.txt'"
check "leaves_ok: 604920 s lifetime accepted, but an identity without a chain keeps the readback from passing" "grep -qx 'leaves_ok_rc=1' '$U/out-certs' && grep -q 'NOT AFTER - NOT BEFORE = 604920s' '$U/leaves.txt' && grep -q 'no certificate chain yet' '$U/leaves.txt'"
# the real background runner under TERM: the exit path must wait for the running command, not kill it.
# The run directory holds no OVERRIDE-APPLIED, so the exit path has nothing to restore and calls no tool.
cat > "$U/unit-term.sh" <<UNIT
DRIVER_SOURCE_ONLY=1 . "$DRV" status "$U/run-term"
echo \$\$ > "$U/run-term/unit.pid"
trap on_exit EXIT; trap 'log "signal TERM"; exit 143' TERM
set_state Unit "xlong under TERM"
xlong 60 "$U/run-term/long.out" sh -c 'sleep 6; echo child finished by itself'
echo "xlong returned \$?"
UNIT
mkdir -p "$U/run-term"; s0=$(date +%s)
/bin/bash "$U/unit-term.sh" > "$U/out-term" 2>&1 & upid=$!
sleep 2; kill -TERM "$(cat "$U/run-term/unit.pid" 2>/dev/null || echo $upid)"; wait $upid; urc=$?; el=$(( $(date +%s) - s0 ))
check "real xlong under TERM: exit 143 only after the child ended by itself (${el}s), no restore attempted without OVERRIDE-APPLIED" \
	"[ $urc = 143 ] && [ $el -ge 5 ] && grep -q 'child finished by itself' '$U/run-term/long.out' && grep -q 'waiting for the running command' '$U/run-term/driver.log' && ! grep -q 'restoring now' '$U/run-term/driver.log'"
if command -v go >/dev/null 2>&1; then
	mkdir -p "$U/gochild" && printf 'package main\nimport "time"\nfunc main() { time.Sleep(30 * time.Second) }\n' > "$U/gochild/main.go" && printf 'module gochild\ngo 1.22\n' > "$U/gochild/go.mod"
	( cd "$U/gochild" && go build -o gochild . ) 2>/dev/null
	cat > "$U/unit-go.sh" <<UNIT
DRIVER_SOURCE_ONLY=1 . "$DRV" status "$U/run"
s=\$(date +%s); xread 2 "$U/gochild/gochild"; echo "go_rc=\$? elapsed=\$(( \$(date +%s) - s ))"
UNIT
	/bin/bash "$U/unit-go.sh" > "$U/out-go" 2>&1
	check "bounded runner ends a Go child too (kubectl, helm, istioctl and docker are Go; a bare alarm+exec does not)" "grep -qE '^go_rc=143 elapsed=[2-5]$' '$U/out-go'"
else
	echo "SKIP  go is not installed; the Go-child bound was not exercised"
fi

echo
echo "assertions failed: $FAILS"
[ "$FAILS" -eq 0 ]
