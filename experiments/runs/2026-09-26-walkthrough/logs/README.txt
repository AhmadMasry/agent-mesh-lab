# The full stdout+stderr of every command the walk executed, in order, 2026-09-26T14:03:08Z..17:05:15Z (the walk),
# 17:06:01Z..17:10:15Z (the one step appended by ruling, 90 to 92, and 93 which counted it), and 17:24:12Z..17:25:00Z
# (94 and 95, the orchestrator's restart after C-9's unmark and the clean check after it, by ruling). 121 files.
# Each file begins with "$ " and the command exactly as it ran, then one line naming the istioctl first on PATH at the
# step's start (client version: 1.31.1 in every one), then the command's unabridged output, and ends with
# "wall <s>s exit <n>"; the make targets and every experiment driver also have a timings.csv row. They were written by
# ../drivers/walk.sh (00 to 82), ../drivers/step-63b.sh (63b, 63c), ../drivers/walk-repeat.sh (90 to 92), and by the
# same run() function inline for 51c, 93, 94 and 95 (their command lines are in the record's driver logs), to a
# scratch directory while the run went on and copied here afterwards, unchanged but for one masking noted below.
#
# Notes on the file names, all about this run and none about the documents' steps.
#
# 1. 00 to 24 are the main walkthrough's steps, the same files as the 2026-09-25 record's, run again from a deleted
#    cluster; 30 to 39c are walkthrough-b.md's; 50 to 65 walkthrough-c.md's standing rows; 70 to 71c its two trials;
#    80 to 82 the closing reads; 90 to 95 the steps appended after the walk.
# 2. The reads between the steps are numbered with the step they belong to (01b, 06c, 30b, 39c, 51b and so on) and
#    carry no timings.csv row; only the make targets and the drivers do.
# 3. 00a-lab-tools.txt is the walkthrough's "Before you start" block, sourced once by the driver in its own shell so
#    that every later command inherited the PATH and the Helm scope it sets; the file's "$ " header is the whole block.
# 4. The commands name experiments/runs/2026-09-26-walkthrough where the walkthroughs' text names
#    experiments/runs/my-walkthrough, in RUN_ITEM, RUNREL, OUTROOT and the paths read from them; nothing else in them
#    differs.
# 5. 30-b-prerequisites.txt and 50-c-prerequisites.txt end in a diff and exit 1 or 0 by what their last command was;
#    both exits were allowed by the driver, as their documents say. 70e-c9-clean-check-under-the-marking.txt was allowed
#    exit 1 as well and exited 0, as the C-9 entry's own driver log records.
# 6. 51c-c1-reads-over-the-saved-files.txt is the two C-1 reads of 51b re-taken over the saved files after the walk,
#    with the corrected filters walkthrough-c.md gives; 63b and 63c ran beside the walk, one second after step 63
#    exited, started by a waiter (../step-63b-driver.txt); 90b's counting tool copy is 93's.
# 7. 90b-d3-batch-repeat.txt carries one masking: a Python traceback from the first, un-keyed counts.py run printed the
#    checkout's absolute path once, replaced by $HOME/ (reading-notes.txt, section 6). No other file needed one.
