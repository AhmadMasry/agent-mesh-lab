# ztunnel certificate renewal across a forced host sleep — the driver

Follow-ups 16, phase 2. One detached script measures when ztunnel 1.31.0 renews a workload leaf after the
Mac that hosts the kind cluster has slept, against hypothesis H of `research.md` §6: the refresh fires at the
wall time `t` where `t − D(t) = R`, with `R` the leaf's half-life point and `D` the guest's
(wall − monotonic) divergence accumulated since that ztunnel process started.

This is a lab measurement on a kind cluster, under this configuration and at these versions; nothing more is claimed.

## Files

| File | What it is |
|---|---|
| `driver.sh` | The driver. Bash 3.2 (`#!/bin/bash`; macOS ships 3.2.57 and it is the only bash on the lab host). Subcommands `preflight`, `run`, `restore`, `status`. |
| `derive-renewals.py` | Python 3, standard library only. Builds `renewals.csv`, `d-series.csv`, `gaps-d.csv` and `summary.txt` from the run's records; also the P1 gate the driver calls after arm C. |
| `test/run-tests.sh` | The offline checks: static checks, ten DRY_RUN scenarios, two interrupted restores, single functions run for real (the bounded runner against a Go child, the background runner under TERM, the parsers, the pmset window on the real log), the derive fixture. No cluster, Docker or power command runs. |
| `test/sim.py` | DRY_RUN's canned readings: a model of H (guest frozen during a gap, wall clock stepped 12 s after it, refresh after `T/2 − 1 min + D` of guest running time). A test fixture, not a measurement. |
| `test/make-derive-fixture.py` | A hand-built run directory with a known D (0, then 1500 s) and one renewal whose bracketing clock samples straddle a step. |
| `test/fixtures/` | `pmset -g custom / batt / assertions / log` as read on the lab host on 2026-09-18, and per scenario what a sleep request does (`<start offset s> <length s>` per line; no file = no effect). |

## What the run changes on the cluster

1. `helm upgrade -i ztunnel …` — the Makefile's own command (chart repository and version read from the Makefile) with a
   second values file, `<RUN_DIR>/ztunnel-ttl-override.yaml`: `env.SECRET_TTL: "10m"` and `logLevel: "info,ztunnel::identity=debug"`.
   The filter goes through the chart's own `logLevel` key: the chart at 1.31.0 always renders `RUST_LOG` from it
   (`templates/daemonset.yaml` 130–131) and appends the `env` map after it, so `RUST_LOG` under `env` would give the
   container two `RUST_LOG` entries. With `logLevel`, `helm template` differs from the committed rendering in two
   lines: `RUST_LOG`'s value and `SECRET_TTL`'s.
2. One probe pod, `lab/zt-probe` (the image under `curl-image` in `versions.yaml`, the lab's non-root securityContext).
3. Arm P4: `kubectl -n istio-system rollout restart ds/ztunnel`.
4. Restore: the same helm command with `deploy/step-2-ambient-agw/ztunnel-values.yaml` alone; the probe pod deleted.

It touches nothing else: no make target, istiod untouched, no file under `deploy/`, the Makefile or `versions.yaml`.
On the host: `pmset sleepnow`, then if needed `osascript -e 'tell application "System Events" to sleep'`. No sudo, no
keep-awake, no power setting changed.

**`make step-3` must be completely finished before `run` starts** (its certificate check restarts ztunnel), and nothing
else may use the cluster until `RESTORE-VERIFIED` exists.

## Start

```sh
RUN_DIR=experiments/runs/$(date +%F)-ztunnel-renewal      # local date of the run
/bin/bash driver.sh preflight "$RUN_DIR"                  # reads only; exit 60 on any FAIL
nohup /bin/bash driver.sh run "$RUN_DIR" >>"$RUN_DIR/driver.out" 2>&1 &
```

`run` repeats the preflight and applies nothing if a check fails. It refuses a run directory that already holds a run.
After the `nohup` line the driver needs no terminal, agent turn or API connection: a frozen process resumes when the
host wakes, and the driver finds the wake itself.

## Watch

```sh
/bin/bash driver.sh status "$RUN_DIR"
tail -f "$RUN_DIR/driver.log"
```

`STATE` holds the arm and a UTC stamp, written atomically at every transition. `progress.env` is rewritten every loop
iteration: gaps so far, first wake, awake seconds, renewals counted.

## Abort

```sh
touch "$RUN_DIR/ABORT"
```

Checked every loop iteration (5 s) and twice right before the sleep request. The driver skips every remaining arm, runs
Restore, and exits 10. `kill -TERM <pid>` also ends in Restore, through the trap (exit 143). `kill -9` and a reboot
cannot be trapped: run the standalone restore.

## Restore by hand

```sh
/bin/bash driver.sh restore "$RUN_DIR"
```

Standalone and idempotent; it writes `driver.pid` while it runs and refuses while a driver (a run or another restore) is alive on that run directory (`FORCE=1` overrides). It runs the
Makefile's helm command with the committed values alone; if that fails, the same upgrade from the chart archive pulled
at Setup (`<RUN_DIR>/chart/`, no network needed); up to `RESTORE_ATTEMPTS` (3) rounds, 60 s apart, each recorded.
`RESTORE-VERIFIED` is written only after every readback passes:

- `helm get values ztunnel -o json` equals the committed values file, parsed;
- the DaemonSet's whole env is identical to the one captured at this run's preflight (`ds-env.standard.txt`: the
  standard lab carries `RUST_LOG=info` from the chart, so the standard is that list, not "no `RUST_LOG`"); it has the
  committed `SECRET_TTL` and a single `RUST_LOG` without an identity or debug directive, and so does every running
  ztunnel pod;
- the rollout is complete (desired = updated = ready = available, generation observed);
- every Leaf that either node's ztunnel holds reads VALID CERT true with NOT AFTER − NOT BEFORE = the committed TTL + 120 s (± 120 s), no identity is without a chain (a node with no Leaf at all passes: the control-plane node holds none in this lab), and
  the tracked identity is present on the worker node (polled up to 300 s);
- `istioctl ztunnel-config log` (a read) shows no `identity=debug`;
- the probe pod this driver created is gone; `helm history` is recorded.

`RESTORE-FAILED` is written **first**, as "restore in progress, not read back yet", and removed only when every readback
has passed; a failed readback replaces its text with the reason. So a restore cut short at any point — TERM, `kill -9`,
a power loss — still leaves the marker, and the script never writes `RESTORE-VERIFIED` for a restore it did not read
back. Under INT/TERM the standalone restore lets a running helm end (a helm upgrade killed half way leaves the release
pending) and exits without starting over; `run`'s exit path does the same wait and then attempts the restore.

## The arms

| Arm | What happens | Ends when |
|---|---|---|
| Setup | preflight; override written; chart archive pulled; `OVERRIDE-APPLIED`; helm upgrade; rollout; anchor recorded with a clock sample; readbacks (DaemonSet env, helm values, active log filter, identity debug lines); probe pod; first leaves at 720 s | leaves read back, or failure → Restore, exit 40 |
| C | instruments only | 1800 s of awake time. Then the P1 gate: `derive-renewals.py --gate-arm C` (≥ 3 renewals of the tracked identity, every measured \|residual\| ≤ 5 s, no VALID CERT false reading). `P1_GATE=strict` (default): a failed gate skips arm T → Restore, exit 30. `P1_GATE=record`: noted, arm T runs |
| T-wait | certificates every 15 s | a renewal of `spiffe://cluster.local/ns/lab/sa/default` on the worker node was seen and its issuance (NOT BEFORE + 120 s) is 30 s old; or 300 s passed (the request then goes out anyway, recorded) |
| T | pre-sleep clock sample, certificate reading and `pmset -g assertions`; `pmset sleepnow`; 60 s watch for a gap or a new "Entering Sleep" line; else `osascript`; 60 s again; else "sleep not produced" → P4, Restore, exit 20. After the first wake: instruments, fast after every gap | **both** ≥ 3900 s awake since the first wake **and** ≥ 2 renewals of the tracked identity since the last gap ≥ 900 s (since the first wake if there was none); hard cap 28 800 s awake → "cap reached" |
| P4 | `rollout restart ds/ztunnel`; new anchor | 2 renewals of the tracked identity, or 900 s awake |
| Restore | see above | readbacks pass (`RESTORE-VERIFIED`) or not (`RESTORE-FAILED`, exit 50) |

**Wake detection.** The loop ticks every 5 s and between every bounded step. A host-clock step of more than 60 s between
two ticks is a gap: recorded in `gaps.csv`, followed by `pmset -g assertions`, clock samples every 5 s for 3 min and
certificate readings every 15 s for 10 min. No single step between two ticks can last 60 s (bounded reads ≤ 45 s; longer
commands run in the background while the loop keeps ticking), so only a suspended process produces a gap. Awake time is
the sum of tick intervals that were not gaps. DarkWakes show up as gaps followed by short running periods; every one is
recorded. If pmset logged the sleep but no gap > 60 s follows within 1200 s of awake time, the window starts then, and
the log says so.

## Outputs (all under `RUN_DIR`; stamps are UTC from `date -u`)

| File | Content |
|---|---|
| `STATE`, `state-history.csv`, `progress.env`, `driver.pid`, `driver.log`, `driver.out` | where the run is; every transition; every changing command with its output and exit code |
| `OVERRIDE-APPLIED`, `RESTORE-VERIFIED`, `RESTORE-FAILED`, `PROBE-POD-CREATED`, `ABORT` | markers. `OVERRIDE-APPLIED` is written just before the helm upgrade is issued, so a crash in the middle still restores |
| `preflight.txt`, `environment.txt` | PASS/FAIL/WARN lines; host, Docker Desktop, VMM, node kernel, privileged, tool versions, ztunnel pods, helm history, the host's sleep total since boot |
| `clock.csv` | per node every 10 s (5 s after a gap): host epoch before/after; guest wall, CLOCK_MONOTONIC (`/proc/timer_list` "now at"), CLOCK_BOOTTIME (`/proc/uptime`), guest wall again, read in one `docker exec`; the host's CLOCK_MONOTONIC − CLOCK_UPTIME_RAW (its total sleep since boot) |
| `certs.csv` | every Leaf row of `istioctl ztunnel-config certificates --node <node>`, both nodes, every 30 s (15 s after a gap). VALID CERT is istioctl's, judged by the host's clock |
| `renewal-events.csv` | the driver's live count: serial changes of the tracked identity on the worker node |
| `csr-counters.csv`, `istiod-metric-names.txt` | istiod's `citadel_server_csr_count` and `citadel_server_success_cert_issuance_count` every 60 s, read from istiod's own port 15014 through the API server's pod proxy (`kubectl get --raw /api/v1/namespaces/istio-system/pods/<istiod>:15014/proxy/metrics`); the series names as exposed, read at preflight |
| `probe.csv` | one in-mesh GET of the worker's Agent Card per minute from `lab/zt-probe`: `curl -sS --retry 0 --max-time 10`; flags in the header; no loop on failure; a failure is a row |
| `gaps.csv`, `arms.csv`, `anchors.csv` | every gap; every arm with awake seconds and renewals seen; every ztunnel (re)start with pods and start times |
| `sleep-attempts.txt`, `pmset-assertions.pre-sleep.txt`, `pmset-assertions/after-gap-<epoch>.txt`, `pmset-assertions.preflight.txt`, `pmset-custom.preflight.txt` | both sleep requests with exit code and output; the assertion snapshots |
| `host-sleep.txt`, `host-sleep-window-raw.txt` | `pmset -g log` for the run window: Sleep/DarkWake/Wake lines verbatim, Assertions counted by kind and verbatim within 2 min before each Sleep; the whole window verbatim (large; a candidate for .gitignore) |
| `logs/*.after-<arm>.log`, `ztunnel-<node>-identity.after-<arm>.log` | whole pod logs with `--timestamps` (the node's clock) collected before each restart replaces the pods; the identity/TLS lines extracted (small) |
| `setup-readback.txt`, `restore-readback.txt`, `certificates.*.txt`, `helm-*.txt`, `rollout.*.txt`, `p1-gate.txt` | readbacks and command outputs |
| `renewals.csv`, `d-series.csv`, `gaps-d.csv`, `summary.txt`, `derive.out` | derived at the end of the run; re-derive any time with `python3 derive-renewals.py "$RUN_DIR"` |

`renewals.csv`, per serial change: `R_prev`, `t_w = NOT BEFORE(next) + 120 s`, `D(t_w)`, `residual = t_w − D(t_w) − R_prev`,
the arm, seconds the old leaf was past NOT AFTER, seconds since the last gap ended. `status` is `ok`, `ambiguous` (the
wall-minus-monotonic offset steps between the two clock samples that bracket `t_w`: no number is given, `D_lo`/`D_hi` are),
`no-bracket`, or `restart: <reason>` (the serial changed across a recorded ztunnel restart: an issuance, not a renewal).
`summary.txt`, per arm: count, min/median/max residual, ambiguous count, minutes each leaf read VALID CERT false,
CSR-counter deltas against issuances counted from serials, D across each gap against the host's own sleep account, and
the `certificate fetch succeeded` lines per collected log.

## Exit codes

`0` all arms, restore read back · `10` ABORT · `20` sleep not produced · `30` P1 gate failed · `40` Setup failed ·
`50` restore not read back · `60` preflight failed, nothing applied · `64` usage · `130/143` INT/TERM.
In every case but 60 and 64 a restore was attempted; only `RESTORE-VERIFIED` says it was read back.

## Offline checks

```sh
/bin/bash test/run-tests.sh /path/to/a/scratch/dir
```

`DRY_RUN=1` routes every cluster, Docker, pmset and osascript command through three wrappers that log the command and
return `test/sim.py`'s reading instead of executing it; shell functions of the same names log `BLOCKED` if anything
calls a tool directly. The clock is a file; fixtures step it forward. Scenarios: `normal` (3 h gap, 40 s running, 1000 s
gap), `cap`, `nosleep`, `osascript` (sleepnow exits 1), `osascript-late` (sleepnow exits 0 without effect), `p1fail`,
`abort-presleep`, `abort-c`, `trap` (TERM in arm C), `restorefail`; then a restore under `kill -9` and one under TERM.
`pmset sleepnow` is never executed by the tests.

## This run (2026-09-19), and what was added after it

The run of this directory is recorded in `findings.md` under
`## Gate 3 / both receivers / ztunnel certificate renewal across host sleep`. Added after the driver exited, from its
records only:

| File | Content |
|---|---|
| `post-analysis.py`, `post-analysis.txt` | the two readings below, and their printed summary |
| `renewals-logstamp.csv` | every renewal of `renewals.csv` paired with the sub-second stamp of ztunnel's "certificate fetch succeeded" line (the collected line's first stamp, the container runtime's; ztunnel's own is the second, at most 0.343 ms earlier on this run's 48 lines); `residual_log_s` is free of the whole-second truncation of certificate stamps |
| `probe-by-validity.csv` | every probe row against the tracked leaf's NOT BEFORE / NOT AFTER, twice: by the host's clock, and by the guest's wall clock at that moment (the clock ztunnel and its peers read), from the nearest `clock.csv` sample. Regenerated after the review, which found that one of the 34 host-clock "expired" rows ran before the guest's clock was stepped: 33 by the guest's clock |
| `driver-log.txt`, `ztunnel-<node>-identity.after-<arm>.txt` | copies of `driver.log` and of the identity extracts: the repository's `.gitignore` leaves out `experiments/runs/**/*.log` |
| `rulings.txt` | the controller's rulings for this run, the author's authorisation, and the change made after the first preflight (the chart's `logLevel` key instead of `RUST_LOG` under `env`) |
| `rebuild/` | the rebuild of the standard lab before the run (seven make targets, each timed) and the clean check |
| `.gitignore` | what is left out of the commit and why: `chart/`, `logs/`, `host-sleep-window-raw.txt`, `*.uncut` |
| `pmset-assertions*.txt`, `pmset-assertions/*.txt` | as the driver wrote them, except that the Kernel Assertions block's nine `0x4=USB` lines were cut after the run and one line put in their place: they end in `owner=<device name>`, the names of the host's USB peripherals, and no reading uses them. The uncut snapshots stay beside them as `*.uncut`, ignored. The driver does not make this cut itself: a later run's snapshots need the same treatment before they are committed |

What the run showed about the driver itself, not yet changed:
- the cap on a long command (`xlong`) counts wall time, so a host sleep inside the command spends it (this ended the
  first restore attempt; the chart-archive route completed it);
- `anchors.csv` takes a terminating pod's row without a start time (one malformed row at P4);
- the driver records no sha256 of itself or of `derive-renewals.py` at its start. That the committed `driver.sh` is the
  one that ran rests on its modification time (34 s before the start) and on the hash equality of the committed file,
  the working copy and the copy it was installed from. One line at the start of the next run would settle it.

**Re-deriving from a clone.** `logs/` is not committed, so `derive-renewals.py` prints "no collected logs" in its
debug-line section when it runs on a clone. The committed extracts `ztunnel-worker-identity.after-<arm>.txt` carry the
same counts of "certificate fetch succeeded" lines: 2 after Setup, 16 after C, 24 after T, 6 after P4, 0 after the
restore (`grep -c`); every other derived file regenerates byte-identically from the committed records.
