# Kubescape image-scan JSON -> one CSV row per finding.
#
# Columns: id,severity,package,version,fixed_in,type
#   id        the advisory identifier (CVE-…, GHSA-…, GO-…)
#   severity  Kubescape's own severity string
#   package   the artifact the finding is against
#   version   the version of that artifact in the image
#   fixed_in  the version(s) Kubescape names as the fix, ";"-joined, or EMPTY when
#             the report carries no fix -- that is, when there is nothing to
#             upgrade to. The empty case is what the findings entry counts.
#   type      Kubescape's artifact type: deb for an operating-system package,
#             go-module for a Go dependency, binary for the interpreter itself.
#
# Sorted by severity (Critical, High, Medium, Low, Negligible, Unknown) then id.
#
# Fields are joined with "," and not quoted. That is checked, not assumed: no
# advisory id, package name, version or type Kubescape has emitted here contains a
# comma or a quote, and fixed_in joins its versions with ";" for that reason. The
# scan target's own output is diffed against the committed CSVs, so a value that
# ever did need quoting would show up as a difference rather than as a silent
# mangling.
def sevrank: {"Critical":0,"High":1,"Medium":2,"Low":3,"Negligible":4,"Unknown":5}[.] // 9;

[ .matches[]?
  | { id:       (.vulnerability.id // ""),
      severity: (.vulnerability.severity // "Unknown"),
      package:  (.artifact.name // ""),
      version:  (.artifact.version // ""),
      fixed_in: ( if (.vulnerability.fix.state? // "") == "fixed"
                     and ((.vulnerability.fix.versions? // []) | length) > 0
                  then (.vulnerability.fix.versions | join(";"))
                  else "" end ),
      type:     (.artifact.type // "") }
]
| sort_by([(.severity | sevrank), .id])
| ["id","severity","package","version","fixed_in","type"],
  (.[] | [.id, .severity, .package, .version, .fixed_in, .type])
| join(",")
