# The full stdout+stderr of every command the walkthrough's run executed, in order, 2026-09-25T21:49:38Z..22:13:18Z.
# Each file begins with "$ " and the command exactly as it ran, then the command's unabridged output, and ends with
# "wall <s>s exit <n>"; the make targets and experiment scripts also have a timings.csv row. They were written by
# ../drivers/walk.sh to a scratch directory while the run went on and copied here afterwards, unchanged.
#
# Three notes on the file names, all about this run and none about the document's steps.
#
# 1. The reads between the steps are numbered with the step they belong to (01b, 06c, 09d and so on) and carry no
#    timings.csv row; only the make targets and the experiment scripts do.
# 2. 00a-lab-tools.txt is the walkthrough's "Before you start" block, sourced once by the driver in its own shell so that
#    every later command inherited the PATH and the Helm scope it sets; the file's "$ " header is the whole block.
# 3. The commands name experiments/runs/2026-09-25-walkthrough where the walkthrough's text names
#    experiments/runs/my-walkthrough, in RUN_ITEM and in the paths read from it; nothing else in them differs.
