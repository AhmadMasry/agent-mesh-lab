# Keeps only the HTTPRoute documents of a rendered multi-document YAML stream.
#
# `make retry-on` and `make retry-off` change routes and nothing else. Two of the
# three route sets live in files that also carry the Gateway, the parameters, the
# ServiceEntry and the backend they belong to, and a kustomization emits every
# resource it reads, so the rendered stream is filtered here before it reaches
# `kubectl apply`. Re-applying an unchanged Gateway would very likely be a no-op,
# but "very likely" is not what the run needs: the routes are the only objects
# these two targets are allowed to touch.
#
# Documents are separated by a line that is exactly "---", which is what
# `kubectl kustomize` emits, and a document is kept when it carries a top-level
# `kind: HTTPRoute` line. Nested kind fields (parentRefs, backendRefs) are
# indented and so cannot match.

function flush() {
	if (keep) {
		if (printed) print "---"
		printf "%s", doc
		printed = 1
	}
	doc = ""
	keep = 0
}

/^---$/ {
	flush()
	next
}

{
	doc = doc $0 "\n"
	if ($0 == "kind: HTTPRoute") keep = 1
}

END {
	flush()
}
