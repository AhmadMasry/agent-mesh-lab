"""Which proxy POD answered each of a repetition's requests, Job 1's and Job 2's separately.

The controller's addition of 2026-09-22: for BOTH rows, record which pod answered Job 2's card GET and which
answered its POST, and whether it was the removed pod or the successor. Derived from the committed files only; no
cluster, no network.

TWO SOURCES, each used where it is definitive, and NEITHER of them a request's access-log STAMP:
  * the two POSTs -- Job 1's SendStreamingMessage and Job 2's SubscribeToTask -- from the RECEIVER'S OWN ingress
    ledger, whose arrival line carries the method and the sender's address; the address is matched against the pod
    IPs the driver recorded before and after the removal. This is what `senders` in summary.csv reports.
    A stamp is not used at all, so the access-line timestamp defect cannot reach it.
  * the two card GETs, which create no A2A arrival and so exist only in a proxy's access log. Each is attributed to
    the pod whose capture holds it -- oldpod.log is the removed pod, newpod.log its successor,
    otherproxy-access.txt the proxy this variant did not touch -- and where one capture holds both, FILE ORDER
    separates them: a proxy writes its lines in the order it finishes them, Job 1 is applied about 4.5 s before
    Job 2, and file order is immune to the defect in a way a stamp is not.
An access line's stamp is written when the request ENDS, not when it begins, which is why a stamp cannot separate
Job 1's cut POST (it ends just after the removal) from Job 2's (it ends when the Task does). That is stated here
because the first version of this program used one and mis-attributed all twenty of Job 1's POSTs on each ingress
row.

It also prints the two tallies the controller's second addition asks for -- how many of each 20 sent a subscription
at all and how many of those reattached, and the executor's own error text per row with whether it varies inside a
row -- so that request-attribution.txt reproduces WHOLE from this one program. In its first committed form the
tallies were appended by a separate one-off script and the .txt did not reproduce from the .py; that is corrected
here and noted because a committed output must say how it was produced.
"""
import csv, os, re, collections

D = "experiments/runs/2026-09-22-b5b-removal-resubscribe"
PLINE = re.compile(r"^(\S+)\t(\S+)\t(.*)$")
ACC = re.compile(r"route=(\S+) .*?http\.method=(\S+) http\.host=(\S+) http\.path=(\S+)")


def access(path):
    out = []
    if not os.path.exists(path):
        return out
    for raw in open(path):
        m = PLINE.match(raw.rstrip("\n"))
        if not m:
            continue
        a = ACC.search(m.group(3))
        if not a:
            continue
        route, method, p = a.group(1), a.group(2), a.group(4)
        out.append("cardGET" if "agent-card" in p else ("modelPOST" if "model-via-agw" in route else "POST"))
    return out


rows = {r["work_item"]: r for r in csv.DictReader(open(f"{D}/rows/summary.csv"))}
post = collections.defaultdict(collections.Counter)
card = collections.defaultdict(collections.Counter)
model = collections.defaultdict(collections.Counter)
lines = collections.Counter()
for variant in sorted(os.listdir(f"{D}/rows")):
    vd = f"{D}/rows/{variant}"
    if not os.path.isdir(vd):
        continue
    for lwi in sorted(os.listdir(vd)):
        d = f"{vd}/{lwi}"
        if not os.path.isdir(d):
            continue
        r = rows[lwi]
        # --- the two POSTs, from the receiver's own ledger (summary.csv's `senders`, recomputed here verbatim)
        for part in r["senders"].split("|"):
            meth, _, who = part.partition("<-")
            job = "Job 1 POST (SendStreamingMessage)" if meth == "SendStreamingMessage" else "Job 2 POST (SubscribeToTask)"
            post[variant][f"{job} <- {who}"] += 1
        # --- the two card GETs, by capture and then by file order inside a capture
        caps = [("oldpod.log", "the REMOVED pod"), ("newpod.log", "its SUCCESSOR"),
                ("otherproxy-access.txt", "the OTHER proxy, untouched")]
        seen = []
        for f, who in caps:
            k = access(f"{d}/{f}")
            lines[variant] += len(k)
            for kind in k:
                if kind == "cardGET":
                    seen.append(who)
                elif kind == "modelPOST":
                    model[variant][f"Job 1's model call <- {who}"] += 1
        assert len(seen) == 2, (lwi, seen)
        card[variant][f"Job 1 card GET <- {seen[0]}"] += 1
        card[variant][f"Job 2 card GET <- {seen[1]}"] += 1

print("WHICH PROXY POD ANSWERED EACH REQUEST, per variant, over its 20 repetitions")
for variant in sorted(post):
    print(f"\n## {variant}   ({lines[variant]} access lines over 20 repetitions; 5 per repetition, the accounting closes)")
    for src in (post, card, model):
        for k in sorted(src[variant]):
            print(f"   {k}: {src[variant][k]} of 20")


print()
print("HOW MANY OF EACH 20 SENT A SUBSCRIPTION AT ALL, AND HOW MANY OF THOSE REATTACHED")
print("(the controller's addition of 2026-09-22: a repetition where no subscription is sent is a counted")
print(" outcome, not a lost repetition. Nothing here was retried, re-sent, or waited for and tried again.)")
allrows = list(csv.DictReader(open(f"{D}/rows/summary.csv")))
for v in sorted({r["variant"] for r in allrows}):
    rs = [r for r in allrows if r["variant"] == v]
    sent = [r for r in rs if r["sub_sent"] == "yes"]
    arr = [r for r in sent if r["arrivals_SubscribeToTask"] == "1"]
    reatt = [r for r in arr if r["client2_first_task_matches_job1"] == "yes"]
    ref = [r for r in sent if r["client2_wire_error"].split(":")[0] not in ("0", "none")]
    late = [r for r in arr if r["task_running_at_sub_arrival"] != "yes"]
    print(f"  {v}: sent {len(sent)} of 20; arrived at the receiver {len(arr)} of {len(sent)}; "
          f"reattached to Job 1's task {len(reatt)} of {len(arr)}; refused on the wire {len(ref)}; "
          f"arrived after the Task had ended {len(late)}")
print()
print("THE EXECUTOR'S OWN ERROR TEXT ON THE LOST-MODEL-CALL EVENT, per row, and whether it varies within a row")
for v in sorted({r["variant"] for r in allrows}):
    rs = [r for r in allrows if r["variant"] == v]
    c = collections.Counter(r["final_state_error"] for r in rs)
    print(f"  {v}: " + "; ".join(f"{n} of 20 {k!r}" for k, n in c.most_common()) +
          f"   (distinct texts within the row: {len(c)})")
print()
print("and the B-4 asymmetry on the CUT-STREAM event, the execution result line, for comparison:")
for v in sorted({r["variant"] for r in allrows}):
    rs = [r for r in allrows if r["variant"] == v]
    c = collections.Counter(r["exec_result_error"] for r in rs)
    print(f"  {v}: " + "; ".join(f"{n} of 20 {k!r}" for k, n in c.most_common()))
