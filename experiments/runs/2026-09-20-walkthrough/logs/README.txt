# The full stdout+stderr of every make target and experiment script this walkthrough ran, in order,
# 2026-09-20T03:43:43Z..04:10:18Z. Each file is the unabridged output of the command docs/walkthrough.md
# shows; the last line of each carries the wall time timings.csv records.
#
# Two notes on the file numbering, both about this run and neither about the document's steps.
#
# 1. The reads between the steps are numbered with the step they belong to (01b, 06c, 09d and so on) and
#    carry no timings.csv row; only the make targets and the experiment scripts do.
# 2. The driver that ran this walkthrough stopped once, after 15b, and was restarted from 15b: the read of
#    the trace backend's service list ended with `kill` on its own port-forward and the driver took that
#    process's 143 for the read's own. Nothing was sent to the cluster in between and no step was repeated;
#    15b was re-read cleanly and is the file here. The gap it left, 03:57:05Z..04:00:21Z, is why the run's
#    first-to-last wall time is longer than the sum of its parts.
