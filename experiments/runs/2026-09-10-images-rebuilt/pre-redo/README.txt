The trace-per-work-item run of the FIRST rollout of this branch, kept as the record
of what was measured then: images built on digest-pinned bases, with a venv chown'd
to 65532, no OS-upgrade layer, the Go binaries on distroless Debian 12, and the
ServiceAccount token still mounted.
The findings entry cites the top-level run only -- the redo, taken after the second
rollout on tag-referenced bases, root-owned files, the apt-upgrade layer, distroless
Debian 13 and automountServiceAccountToken: false. Both runs produced identical
counts, which is the point of keeping this one. image-after.txt, image-size.txt,
readonly-proofs.txt and readonly-run.txt here describe the first images; the files
of the same names one level up describe the final ones. cluster-rollout.txt here is
the first rollout.
