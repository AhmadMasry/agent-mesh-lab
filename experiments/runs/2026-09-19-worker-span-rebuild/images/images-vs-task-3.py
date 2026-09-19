"""Follow-ups 19, task 3c, reading (c): the images this cluster runs beside the images task 3's cluster ran.

Both sides are the output of the same reader, experiments/runs/2026-09-19-currency-rebuild/pins/containers.py, run
unedited on `kubectl get pods -A -o json`, and `helm list -A -o json`. Pod names, start stamps and the number of
finished loadgen Job pods are per cluster and per moment, so the comparison is made on what identifies an image:
for every (namespace, container name), the SET of (spec_image, image_id) pairs seen on each side. Nothing is masked:
both sets are printed whole. A row is `lab's own build` when its spec_image is one the lab builds (ko's kind.local/
images and orchestrator:dev), and `third-party` otherwise.

  python3 images-vs-task-3.py <task-3 containers.csv> <this containers.csv> <task-3 helm-list.json> <this helm-list.json> <out.csv>
"""
import csv
import json
import sys

t3c, thc, t3h, thh, out = sys.argv[1:6]


def own(spec):
    return spec.startswith("kind.local/") or spec.startswith("ko.local/") or spec.split(":")[0] == "orchestrator"


def load(path):
    groups = {}
    for r in csv.DictReader(open(path, newline="")):
        groups.setdefault((r["namespace"], r["container"]), set()).add((r["spec_image"], r["image_id"]))
    return groups


a, b = load(t3c), load(thc)
rows = []
for key in sorted(set(a) | set(b)):
    sa, sb = a.get(key, set()), b.get(key, set())
    specs = {s for s, _ in sa | sb}
    kind = "lab's own build" if any(own(s) for s in specs) else "third-party"
    verdict = "equal" if sa == sb else ("only in task 3" if not sb else ("only here" if not sa else "differs"))
    rows.append([key[0], key[1], kind, verdict,
                 " ; ".join("%s @ %s" % p for p in sorted(sa)), " ; ".join("%s @ %s" % p for p in sorted(sb))])
with open(out, "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["namespace", "container", "class", "verdict", "task_3_spec_image_at_image_id", "this_spec_image_at_image_id"])
    w.writerows(rows)

third = [r for r in rows if r[2] == "third-party"]
lab = [r for r in rows if r[2] != "third-party"]
print("(namespace, container) groups: %d; third-party: %d, of them equal: %d; lab's own builds: %d, of them equal: %d" % (
    len(rows), len(third), sum(1 for r in third if r[3] == "equal"), len(lab), sum(1 for r in lab if r[3] == "equal")))
for r in rows:
    if r[3] != "equal":
        print("  %s  %s/%s" % (r[3], r[0], r[1]))
        print("    task 3: %s" % r[4])
        print("    here:   %s" % r[5])


def helm(path):
    return {(r["name"], r["namespace"]): (r["status"], r["chart"], r["app_version"]) for r in json.load(open(path))}


ha, hb = helm(t3h), helm(thh)
print("helm releases: task 3 %d, here %d; equal in status, chart and app version: %d" % (
    len(ha), len(hb), sum(1 for k in ha if ha.get(k) == hb.get(k))))
for k in sorted(set(ha) | set(hb)):
    mark = "equal" if ha.get(k) == hb.get(k) else "DIFFERS"
    print("  %-8s %-20s %-20s task 3: %s | here: %s" % (mark, k[0], k[1], ha.get(k), hb.get(k)))
