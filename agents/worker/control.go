package main

import (
	"encoding/json"
	"io"
	"net/http"
	"sync"
)

// Receiver-side injection modes. Both fail a request that has already been
// counted at the ingress ledger, which is what lets a later task tell an
// arrival apart from a completed dispatch.
const (
	// modeHTTP503BeforeDispatch answers 503 after the arrival line is written
	// and before the A2A SDK sees the request.
	modeHTTP503BeforeDispatch = "http503-before-dispatch"
	// modeCloseAfterRead closes the connection after the body has been read,
	// so the client sees a transport failure and no status at all.
	modeCloseAfterRead = "close-after-read"
)

func isKnownInjectionMode(mode string) bool {
	return mode == modeHTTP503BeforeDispatch || mode == modeCloseAfterRead
}

// injectRequest is the POST /control/inject body.
type injectRequest struct {
	Mode string `json:"mode"`
	LWI  string `json:"lwi"`
}

// injector holds the work items armed for one injection each. It contains no
// retry logic and no repetition: take returns a mode once and disarms it, so
// an armed work item fires on exactly one delivery and every later delivery
// of the same work item is served normally.
//
// The armed set is per process. Arming through a Service therefore reaches one
// pod, and this receiver runs a single replica (deploy/base/worker.yaml); if a
// replica count ever changes, an arming could land on a different pod than the
// request it was meant for.
type injector struct {
	mu    sync.Mutex
	armed map[string]string // logical_work_item_id -> mode
}

func newInjector() *injector { return &injector{armed: map[string]string{}} }

func (i *injector) arm(mode, lwi string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.armed[lwi] = mode
}

// take returns the mode armed for lwi and disarms it. The second call for the
// same work item reports nothing armed.
func (i *injector) take(lwi string) (string, bool) {
	if lwi == "" {
		return "", false
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	mode, ok := i.armed[lwi]
	if ok {
		delete(i.armed, lwi)
	}
	return mode, ok
}

func (i *injector) reset() {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.armed = map[string]string{}
}

func (i *injector) handleInject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return
	}
	var req injectRequest
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if !isKnownInjectionMode(req.Mode) {
		http.Error(w, "unknown mode", http.StatusBadRequest)
		return
	}
	if req.LWI == "" {
		http.Error(w, "lwi is required", http.StatusBadRequest)
		return
	}
	i.arm(req.Mode, req.LWI)
	w.WriteHeader(http.StatusNoContent)
}

func (i *injector) handleReset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	i.reset()
	w.WriteHeader(http.StatusNoContent)
}
