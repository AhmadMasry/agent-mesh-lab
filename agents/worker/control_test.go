package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func postInject(t *testing.T, inj *injector, body string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	inj.handleInject(w, httptest.NewRequest(http.MethodPost, "/control/inject", strings.NewReader(body)))
	return w
}

// One armed work item fires once. Nothing here retries: take disarms, so a
// second delivery of the same work item is served normally.
func TestInject_ArmsOnceForWorkItemAndDisarmsAfterFiring(t *testing.T) {
	inj := newInjector()
	if w := postInject(t, inj, `{"mode":"http503-before-dispatch","lwi":"w1"}`); w.Code != http.StatusNoContent {
		t.Fatalf("inject status = %d, want 204: %s", w.Code, w.Body.String())
	}
	mode, ok := inj.take("w1")
	if !ok || mode != "http503-before-dispatch" {
		t.Fatalf("first take = %q/%v, want http503-before-dispatch/true", mode, ok)
	}
	if mode, ok := inj.take("w1"); ok || mode != "" {
		t.Errorf("second take = %q/%v, want the work item disarmed", mode, ok)
	}
	if mode, ok := inj.take("w2"); ok || mode != "" {
		t.Errorf("take of an unarmed work item = %q/%v, want empty/false", mode, ok)
	}
}

func TestInject_RejectsUnknownModeAndMissingLWI(t *testing.T) {
	inj := newInjector()
	for _, body := range []string{
		`{"mode":"nonsense","lwi":"w1"}`,
		`{"mode":"http503-before-dispatch"}`,
		`{"mode":"","lwi":"w1"}`,
		`{not json`,
	} {
		if w := postInject(t, inj, body); w.Code != http.StatusBadRequest {
			t.Errorf("inject %s: status = %d, want 400", body, w.Code)
		}
	}
	if mode, ok := inj.take("w1"); ok {
		t.Errorf("a rejected inject armed %q", mode)
	}
}

func TestControl_MethodNotAllowed(t *testing.T) {
	inj := newInjector()
	for name, h := range map[string]http.HandlerFunc{"inject": inj.handleInject, "reset": inj.handleReset} {
		w := httptest.NewRecorder()
		h(w, httptest.NewRequest(http.MethodGet, "/control/"+name, nil))
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("GET /control/%s: status = %d, want 405", name, w.Code)
		}
	}
}

func TestReset_ClearsArmedInjections(t *testing.T) {
	inj := newInjector()
	postInject(t, inj, `{"mode":"http503-before-dispatch","lwi":"w1"}`)
	postInject(t, inj, `{"mode":"close-after-read","lwi":"w2"}`)
	w := httptest.NewRecorder()
	inj.handleReset(w, httptest.NewRequest(http.MethodPost, "/control/reset", nil))
	if w.Code != http.StatusNoContent {
		t.Fatalf("reset status = %d, want 204", w.Code)
	}
	for _, lwi := range []string{"w1", "w2"} {
		if mode, ok := inj.take(lwi); ok {
			t.Errorf("%s still armed with %q after reset", lwi, mode)
		}
	}
}

// The unit tests above call the handlers directly. This one asserts the routed
// contract the cluster sees: the control endpoints answer 405 themselves rather
// than falling through to the A2A handler, and none of them is ledgered.
func TestControl_RoutedMethodNotAllowedAndNotLedgered(t *testing.T) {
	var out bytes.Buffer
	a2aCalls := 0
	a2a := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { a2aCalls++; w.WriteHeader(http.StatusOK) })
	root := newRootMux(a2a, newLineWriter(&out), newInjector())

	for _, tc := range []struct {
		method, path, body string
		want               int
	}{
		{http.MethodGet, "/control/inject", "", http.StatusMethodNotAllowed},
		{http.MethodGet, "/control/reset", "", http.StatusMethodNotAllowed},
		{http.MethodPut, "/control/inject", "", http.StatusMethodNotAllowed},
		{http.MethodPost, "/control/inject", `{"mode":"http503-before-dispatch","lwi":"w1"}`, http.StatusNoContent},
		{http.MethodPost, "/control/reset", "", http.StatusNoContent},
		{http.MethodGet, "/healthz", "", http.StatusOK},
		{http.MethodPost, "/healthz", "", http.StatusMethodNotAllowed},
	} {
		w := httptest.NewRecorder()
		root.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
		if w.Code != tc.want {
			t.Errorf("%s %s: status = %d, want %d (body %q)", tc.method, tc.path, w.Code, tc.want, w.Body.String())
		}
	}
	if a2aCalls != 0 {
		t.Errorf("the A2A handler was reached %d times from control or health paths", a2aCalls)
	}
	if out.String() != "" {
		t.Errorf("control and health traffic was ledgered: %q", out.String())
	}
}

// The end-to-end path A.2 depends on: arm through the control endpoint on the
// mux the process serves, then watch the injection fire on a routed request for
// that work item, then watch the next request for the same work item go through.
// The test never touches the injector object, so this is what asserts that the
// endpoint and the middleware share one.
func TestControl_ArmThenFireThroughRoutedApp(t *testing.T) {
	var out bytes.Buffer
	a2aCalls := 0
	a2a := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { a2aCalls++; w.WriteHeader(http.StatusOK) })
	root := newRootMux(a2a, newLineWriter(&out), newInjector())

	// The work item in the recorded a2a-go body is "go-dump".
	w := httptest.NewRecorder()
	root.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/control/inject",
		strings.NewReader(`{"mode":"http503-before-dispatch","lwi":"go-dump"}`)))
	if w.Code != http.StatusNoContent {
		t.Fatalf("arm: status = %d, want 204: %s", w.Code, w.Body.String())
	}
	if out.String() != "" {
		t.Fatalf("arming was ledgered: %q", out.String())
	}

	send := func() *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		root.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody)))
		return rec
	}

	first := send()
	if first.Code != http.StatusServiceUnavailable {
		t.Fatalf("armed request: status = %d, want 503", first.Code)
	}
	if got := strings.TrimSpace(first.Body.String()); got != `{"error":"injected"}` {
		t.Errorf("armed request body = %q", got)
	}
	if a2aCalls != 0 {
		t.Errorf("the A2A handler was reached %d times for the armed request", a2aCalls)
	}
	lines := ingressLines(t, out.String())
	if len(lines) != 2 {
		t.Fatalf("want an arrival and a response line, got %d: %q", len(lines), out.String())
	}
	if lines[0].Phase != "arrival" || lines[0].LogicalWorkItemID != "go-dump" || lines[0].Injection != "" {
		t.Errorf("arrival = %+v", lines[0])
	}
	if lines[1].Phase != "response" || lines[1].Injection != modeHTTP503BeforeDispatch || statusOf(t, lines[1]) != http.StatusServiceUnavailable {
		t.Errorf("response = %+v", lines[1])
	}

	// One arming, one firing: the same work item is served normally next time.
	second := send()
	if second.Code != http.StatusOK {
		t.Fatalf("second request: status = %d, want 200 (the work item should be disarmed)", second.Code)
	}
	if a2aCalls != 1 {
		t.Errorf("the A2A handler was reached %d times for the second request, want 1", a2aCalls)
	}
	lines = ingressLines(t, out.String())
	if len(lines) != 4 || lines[3].Injection != "" || statusOf(t, lines[3]) != http.StatusOK {
		t.Errorf("second response = %+v (of %d lines)", lines[len(lines)-1], len(lines))
	}
}
