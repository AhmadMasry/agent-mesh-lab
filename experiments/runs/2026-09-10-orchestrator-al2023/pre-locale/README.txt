These files measured and counted the orchestrator image BEFORE glibc's locale archive was kept:
the assembled root of 2026-09-10, with /usr/lib/locale removed by the rootfs stage's second `rm -rf`.
They are kept as the removed side of that comparison; the findings entry cites the top-level run only.
