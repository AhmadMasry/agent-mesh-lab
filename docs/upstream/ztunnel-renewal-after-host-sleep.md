# Draft comment — istio/ztunnel#1481, "Certificate renewal doesn't take into account time while machine is asleep"

Status: **posted** by the author on 2026-09-19T14:59:32Z as a comment on the existing issue:
https://github.com/istio/ztunnel/issues/1481#issuecomment-5742868160. The posted text is a first-person version of
the text below; this file keeps the text as drafted, with its record table.

Issue re-read 2026-09-19T02:27:12Z (`gh api repos/istio/ztunnel/issues/1481`): **open**, created 2025-03-10 by
howardjohn (MEMBER), no labels, last updated 2025-03-10. Its body: *"We set a timer for 12hr to renew. If the machine
sleeps for 2 days and wakes up, that is not considered, so the cert expires."* Its one comment, same author: *"Not sure
sidecars handle this or not either. Or kubernetes JWT mounting"*. The comment below adds only what those two texts do
not say.

Source read at tag `1.31.0` (tag object `e6fdcc5bd462e6db9f6c844aed5e054a01343a0f`), 2026-09-19T02:28:56Z, from
`https://raw.githubusercontent.com/istio/ztunnel/1.31.0/<path>`. `master` at `db40ece85ffc98b493ed75da18e1f2a276f4d452`
(2026-09-18) has byte-identical `src/identity/manager.rs` and `src/time.rs`.

Records: `experiments/runs/2026-09-19-ztunnel-renewal/` in this repository; the findings entry is
`## Gate 3 / both receivers / ztunnel certificate renewal across host sleep` in `findings.md`.

---

## The comment

A measured reproduction, in case it helps: ztunnel 1.31.0 (the release image, `profile: ambient`, by the Istio Helm
charts) on a two-node kind cluster, Docker Desktop 4.91.0 on macOS with the Apple Virtualization framework, node
kernel 7.0.12-linuxkit. `SECRET_TTL=10m` on ztunnel so that a leaf's half-life is 4 min after issuance, identity
debug logging on, and the laptop put to sleep once for 17 minutes. One run; two identities on one node.

What was measured:

- **Awake (30 min):** 14 renewals, each at NOT BEFORE + half the lifetime to within 0.06 s (by the stamps of
  ztunnel's `certificate fetch succeeded` debug lines; certificate stamps are whole seconds).
- **Across the host's sleep** the VM's CLOCK_MONOTONIC stood still and its wall clock was stepped forward about 25 s
  after the wake: (wall − monotonic) grew by 1020.56 s, against 1020.48 s of sleep by the host's own clocks.
- **The first renewal after the wake** came 1020 s after the leaf's half-life point, which was 660 s after its
  NOT AFTER. It did not come at the wake, and it did come: with the measured clock divergence D subtracted, it was
  on time to +0.016 s.

Three things this adds to the issue as written:

1. **The delay is not confined to the leaf that spanned the sleep; it applies to every later leaf until ztunnel
   restarts.** The wall↔monotonic `Converter` is built once, in `SecretManager::new_with_client`
   (`src/identity/manager.rs` 570; `src/time.rs` 18–43), and every refresh point goes through it
   (`manager.rs` 413), so each refresh fires when *wall time − D* reaches the half-life point, D being the divergence
   accumulated since the process started. Measured: with the host awake again, the next renewals came 21 min 00 s
   apart instead of 4 min (4 min + 1020 s), each with the same residual as when awake (+0.015 to +0.059 s, six
   renewals). Every leaf was valid for 10 min and then past NOT AFTER for 11 min of each 21 min cycle. A
   `rollout restart` of the DaemonSet returned the cadence to 4 min at once (D = 0 for the new process). With the
   default 24 h lifetime the same arithmetic means: once a ztunnel has accumulated more than 12 h 01 min of such
   divergence, every leaf it holds expires before its refresh, even if the machine never sleeps again.

2. **An expired leaf is kept and used, not re-requested.** `start_fetch` posts a request only when the cached state
   is `Initializing` (`manager.rs` 598–627, `init_pri` at 693); `WorkloadCertificate::is_expired`
   (`src/tls/certificate.rs` 398–400) has no caller in `manager.rs`. Measured: while the leaf was past NOT AFTER by
   the node's own clock, 33 requests crossed the mesh with the expired identity, one per minute (2 in what was left of
   the first window once the node's clock had been stepped, then 11, 10 and 10 in the three later windows, the last
   cut short by the restart), and istiod's
   `citadel_server_csr_count` did not move; it rose only by the late renewals. (All 33 returned HTTP 200. At one
   request a minute they stay inside the 5 min pooled-connection release, `src/config.rs` 105, so this run does not
   show whether a new handshake would have failed.)

3. **Nothing is logged.** The success line is `debug` (`manager.rs` 409), there is no line for a refresh that is
   pending past NOT AFTER, and ztunnel's log for the whole period has no line at warn or error. At the default
   filter the condition is invisible on the ztunnel side; `istioctl ztunnel-config certificates` shows it as
   `VALID CERT false` with an unchanged serial.

One point on a fix: in a VM whose host sleeps, the guest is not suspended, so CLOCK_BOOTTIME does not help. Here
`/proc/uptime` (CLOCK_BOOTTIME) and the kernel's monotonic time moved together across the freeze, to within 0.006 s
over the run; only the wall clock, which is what NOT AFTER and the peers' verification use, was stepped. A comparison
against the wall clock, when a cached leaf is handed out or on a periodic check, would cover both the suspended
machine of this issue and the frozen VM. No patch is attached.

---

## Where each number comes from

| Claim | Record |
|---|---|
| 14 awake renewals, residuals +0.015 / +0.033 / +0.057 s by the sub-second stamp of the debug line (the collected line's first stamp, the container runtime's; ztunnel's own, the second, is at most 0.343 ms earlier); −0.002 to 0.000 s by certificate stamps | `renewals-logstamp.csv`, `post-analysis.txt`, `summary.txt` (arm C) |
| (wall − monotonic) grew 1020.557 s; host asleep 1020.476 s; step 21–27 s after the wake | `gaps-d.csv`, `d-series.csv` (00:55:39Z–00:56:05Z), `host-sleep.txt` |
| first renewal after the wake at 00:58:43Z, R_prev 00:41:43Z, NOT AFTER 00:47:43Z, 184 s after the wake; residual −0.558 s by certificate stamps, +0.016 s by the debug line's stamp 00:58:43.574Z | `renewals.csv`, `renewals-logstamp.csv`, `ztunnel-worker-identity.after-T.txt` |
| later renewals 01:19:43Z, 01:40:43Z; six post-wake residuals +0.015 to +0.059 s; each leaf past NOT AFTER for 660 s of each 1260 s cycle: 35.1 min of the 65.1 min after the wake by the leaves' own stamps (184 + 660 + 660 + 602 s); 73 of 148 readings per leaf VALID CERT false, 33.9 min as a sum over readings | `renewals.csv`, `renewals-logstamp.csv`, `summary.txt` (arm T), `certs.csv` |
| restart 02:00:45Z, renewals 02:04:45Z and 02:08:45Z, D = 0 | `renewals.csv` (arm P4), `anchors.csv` |
| CSR counter +6 in arm T, equal to the six serial changes. Over the run +26 = 24 renewals + the 2 issuances of the restart; its last reading (02:08:39Z) precedes the final pair of renewals (02:08:45Z) by six seconds, so the run's 26 renewals + 2 restart issuances = 28 serial changes; debug lines 30 = 2 issuances at start + 28 | `summary.txt`, `csr-counters.csv` |
| 33 probes HTTP 200 while the leaf was past NOT AFTER by the guest's clock (34 by the host's: the first, host 00:55:39Z, ran before the guest's wall clock was stepped, at about 00:38:39Z by the guest); 3 + 11 + 10 + 10 by window on the host's count; 104/104 HTTP 200 over the run | `probe-by-validity.csv`, `post-analysis.txt` |
| 0 warn or error lines | the whole pod log was read for this (`logs/`, not committed); its identity and TLS lines are in `ztunnel-worker-identity.after-T.txt` |
| CLOCK_BOOTTIME against CLOCK_MONOTONIC, at most 0.006 s apart | `d-series.csv` (columns `D_mono_s`, `D_boot_s`) |
| `SECRET_TTL=10m`, identity debug filter, the chart's `logLevel` key | `ztunnel-ttl-override.yaml`, `setup-readback.txt`, `rulings.txt` item 6 |
