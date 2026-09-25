GO_SOURCES_PATHS=(agents/worker fixtures/mockllm internal go.mod go.sum)
GO_SOURCES_DIRTY="$(git status --porcelain -- "${GO_SOURCES_PATHS[@]}" 2>/dev/null || true)"
CHECKOUT_GO_SOURCES_HASH="$(git ls-files -s -- "${GO_SOURCES_PATHS[@]}" ':!**/*_test.go' 2>/dev/null | git hash-object --stdin 2>/dev/null || true)"
