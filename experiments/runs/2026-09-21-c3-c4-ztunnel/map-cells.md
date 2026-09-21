# Experiment C, C-3 and C-4 — the map cells these readings fill

The skeleton is `.superpowers/sdd/experiment-c-prep/map-skeleton.md`; C-1's filled first column is
`experiments/runs/2026-09-20-c1-observation/observation-map.md`. This file fills the ztunnel cells of the
skeleton's §2 (what each layer can ENFORCE) and items 9 and 10 of its §3 list. Every number below is in
`counts.csv` (by `counts.sh`) or in the reading file named beside it, each under its command and read stamp.
Pins: the Versions line of the two entries, read back into `versions.txt`.

## §2, row "ztunnel" — `AuthorizationPolicy` by `selector`, L4 attributes

| Cell | Before C-3/C-4 | Now |
|---|---|---|
| (a) allow-only-the-proxy on a receiver, three caller paths counted (§3 item 9) | TO MEASURE | **LAB (C-3 entry, 2026-09-21).** Istio's own recipe on the worker, `principals: cluster.local/ns/agentgateway-waypoint/sa/agw-central`, status `ZtunnelAccepted=True` "attached to ztunnel" (`c3-policy.txt`). Through `agw-central`: delivered, 1/1/1/1/1 by `gate2-single-clean.sh`. Direct to the pod: refused, curl exit 56 ×2, 0 ledger lines, ztunnel "connection closed due to policy rejection: allow policies exist, but none allowed" ×2 naming `spiffe://cluster.local/ns/lab/sa/default`. Through the ingress on a fresh connection: refused, 503 ×2, 0 ledger lines, the same ztunnel reason ×2 naming `spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress`. Through the ingress on a connection opened 18 s BEFORE the policy: delivered, 1/1/1/1/1 — the connection was not closed when the policy arrived and its request was delivered, while new connections were being refused half a second earlier (`c3-ztunnel.txt`, lifetime 197549 ms). Whether ztunnel re-checked it and let it pass or never re-checked it, the record cannot tell; ztunnel 1.31.0's `PolicyWatcher` is built to close such a connection, so the C-3 entry names it a candidate for a reproduction, with a hypothesis from the source that is not a reading |
| (b) the same policy with `to.operation.methods` (§3 item 10) | TO MEASURE | **LAB (C-4 entry, 2026-09-21).** Accepted by the API server ("configured"), status `ZtunnelAccepted=True`, reason `UnsupportedValue`: "ztunnel does not support HTTP attributes (found: methods). In ambient mode you must use a waypoint proxy to enforce HTTP rules. Within an ALLOW policy, rules matching HTTP attributes are omitted. This will be more restrictive than requested." ztunnel's copy: `Allow`, `rules: []`. istiod's log: one push line, 0 warn or error lines. Every caller refused, the GET the rule names as well as the POST: 6 of 6 requests, 0 ledger lines on 3 of 3 work items, 6 ztunnel policy-rejection lines naming three identities (`c4-*.txt`) |
| "Can the rule be written?" | DOC: no (I-L4 l.66) | DOC and LAB agree, for the one-rule ALLOW policy tested: the object is written and accepted, and its status says the HTTP rule was omitted; what enforces is an ALLOW policy with no rule, so nothing reaches the worker. istiod's source treats a multi-rule ALLOW (only the HTTP-bearing rules omitted) and a DENY (enforced without its HTTP rules) differently; neither was applied |

## §1, row "ztunnel, L4", column "Caller identity" — what enforcement adds to C-1's reading

C-1 read the identity the receiver's ztunnel is given. C-3 enforces on it: the refusal lines name the identity
each caller arrived with — `ns/lab/sa/default` for a lab pod dialling direct, the ingress's own service account
for the ingress, `agw-central`'s for the waypoint path — and the policy admits by that name alone. Every lab
workload runs as `ns/lab/sa/default` (prep report §3.1), so on this lab as built the policy separates PATHS, not
callers: the load client (through `agw-central`) and the curl pod (direct) carry the same identity and one was
admitted and the other refused, and anything that addresses the worker Service is admitted as `agw-central`.

## Still TO MEASURE after this run

Skeleton §3 items 1-8, 11 and 12, unchanged; and §2's row "ztunnel, at the proxy itself" for the
ztunnel-captured ingress proxy (the skeleton leaves it to the author). C-4 answered its cell for one HTTP
attribute, `methods`, in a one-rule ALLOW policy; `paths`, `hosts`, the `request.*` conditions, a DENY policy and a
multi-rule ALLOW policy were not applied. C-3's pre-policy connection is a candidate for a reproduction (its entry's
Follow-up), not a filled cell.

## Files

`overlay-c3/`, `overlay-c4/` — build to the applied objects, compared with the `last-applied-configuration` in
`c3-policy.txt` and `c4-policy.txt` (kept here, not under `deploy/`; the entry says why) ·
`phases.txt` — the stamp of every apply, send window and removal · `send-one.sh` — the driver, one GET and one
POST per work item, `--retry 0` · `rec.sh` — how every reading was recorded · `c3-*.txt`, `c4-*.txt` — policy
object and status, ztunnel's copy, ztunnel lines, istiod log, both proxies' access lines · `proxy-spans.sh`,
`proxy-spans.txt` — each proxy's SERVER span by the trace id the send carried · `worker-arrivals.txt` — every
arrival at the worker in the run, and the refused `messageId`s grepped in its whole log · `removal.txt` — the
delete and the read-back · `counts.sh`, `counts.csv` · `summary.csv`, `g2c-c3-*/` — C-3's committed-script
run · `after/` — the committed script after removal · `c34-*/` — one directory per driver work item ·
`versions.txt` · `host-sleep.txt`, `host-sleep-windows.csv`
