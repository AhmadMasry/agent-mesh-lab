Mutants of experiments/gate3-matrix.sh's Go-sources lines for experiments/lib/go-sources-lists.sh,
each checked against the repository's Makefile by make test, which requires every one to FAIL.
Each file holds only the lines the checker reads, as the harness writes them, and the one line that makes it a mutant.
  pre-fix.sh        the lines as they stood before follow-ups 22 (no fixtures/extauthz; the exclusion outside the array)
  no-extauthz.sh    the exclusion inside the array, fixtures/extauthz missing
  extra-pathspec.sh the list right, but the ls-files command adds a pathspec after the array
  appended-list.sh  the list right, then changed after its definition by GO_SOURCES_PATHS+=(...) (follow-ups 22 review, M1 m3)
  command-in-comment.sh the ls-files command's exact text kept in a comment, the real line passing a slice of the array (follow-ups 22 review, M1 m4)
