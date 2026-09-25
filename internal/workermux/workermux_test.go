package workermux

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

func TestAgentCardPath_IsTheSDKs(t *testing.T) {
	if AgentCardPath != a2asrv.WellKnownAgentCardPath {
		t.Fatalf("AgentCardPath %q; a2asrv.WellKnownAgentCardPath %q", AgentCardPath, a2asrv.WellKnownAgentCardPath)
	}
}

// Which handler each path reaches, and where Go's ServeMux answers itself.
func TestRouting(t *testing.T) {
	mark := func(name string) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Header().Set("X-Handler", name) })
	}
	h := NewRoot(mark("healthz"), mark("inject"), mark("reset"), NewA2A(mark("card"), mark("rest"), mark("jsonrpc")))
	for _, tc := range []struct{ method, target, want string }{
		{"GET", "/healthz", "healthz"},
		{"POST", "/control/inject", "inject"},
		{"POST", "/control/reset", "reset"},
		{"GET", "/.well-known/agent-card.json", "card"},
		{"POST", "/message:send", "rest"},
		{"POST", "/message:stream", "rest"},
		{"GET", "/tasks", "rest"},
		{"POST", "/tasks/t:subscribe", "rest"},
		{"GET", "/extendedAgentCard", "rest"},
		{"POST", "/", "jsonrpc"},
		{"POST", "/x", "jsonrpc"},
		{"POST", "/message:send/", "jsonrpc"},
		{"POST", "/healthz/", "jsonrpc"},
		{"POST", "/%74asks/t:subscribe", "rest"},
		{"POST", "/tasks%2Ft:subscribe", "jsonrpc"},
		{"POST", "//", "307"},
		{"POST", "/tasks/./t:subscribe", "307"},
	} {
		r := httptest.NewRequest(tc.method, "http://w"+tc.target, strings.NewReader(""))
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		got := w.Header().Get("X-Handler")
		if w.Code == http.StatusTemporaryRedirect {
			got = "307"
		}
		if got != tc.want {
			t.Errorf("%s %s: %q; want %q", tc.method, tc.target, got, tc.want)
		}
	}
}
