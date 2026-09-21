package main

import "fmt"

const (
	modeHTTP500        = "http500"
	modeClose          = "close"
	modeDelayThenClose = "delay-then-close"
	modeStale          = "stale"
	// modeDelay sleeps delay_ms and then answers as a call with no injection
	// would; its invocation line reads ok, client-gone or write-failed
	// (delayThenAnswer has what each is read from).
	//
	// The callers' ceilings bound delay_ms, not this fixture (whose own write
	// deadline is counted from the end of the delay, main.go). As they stand:
	//   - worker (Go): MODEL_TIMEOUT_S, default 60 s, is both the model client's
	//     overall Timeout and its ResponseHeaderTimeout (agents/worker/main.go
	//     modelTimeout, internal/httpclient New).
	//   - orchestrator (Python): ModelClient(timeout=60.0), an httpx2 timeout
	//     applied per phase, so the wait for the answer is bounded at 60 s; there
	//     is no environment knob (agents/orchestrator/orchestrator/model.py).
	//   - the model route on agw-central, between either caller and this mock:
	//     agentgateway sets no default request or backend timeout, read from its
	//     source at v1.5.0 (the Experiment B preparation, section 6.1:
	//     crates/agentgateway/src/http/timeout.rs l.23 and l.31, the controller's
	//     builtin_helpers.go l.18-20 and l.32-33); the lab's route sets none.
	//     Read, not measured.
	// Both 60 s ceilings start at the model call, so neither counts the time
	// before it. For both receivers delay_ms stays under 60 000 less the answer's
	// own transfer. The clocks that do count the time before and after the model
	// call are the load client's: its 90 s Client.Timeout and its 2-minute
	// context span the whole A2A request, so they bound delay_ms plus everything
	// else in that request. Experiment B's timeout chain (the prep report,
	// section 7.3) puts the usable window at about 40-50 s.
	//
	// A caller that reaches its ceiling closes the connection, and the call is
	// then recorded as client-gone at that moment. That is measured with a
	// direct Go caller (delay_test.go, a 200 ms client timeout); through
	// agw-central it is Experiment B-3's to measure.
	modeDelay = "delay"
)

func isKnownMode(mode string) bool {
	switch mode {
	case modeHTTP500, modeClose, modeDelayThenClose, modeStale, modeDelay:
		return true
	default:
		return false
	}
}

// injectRequest is the POST /control/inject body. AtCount and DelayMs are
// pointers so an absent field can be told apart from an explicit zero.
type injectRequest struct {
	Mode    string `json:"mode"`
	AtCount *int   `json:"at_count,omitempty"`
	LWI     string `json:"lwi,omitempty"`
	DelayMs *int   `json:"delay_ms,omitempty"`
}

// injectionConfig is the validated, in-memory injection armed by the last
// /control/inject call. AtCount == 0 and LWI == "" both mean "unset"; the
// validation in newInjectionConfig guarantees exactly one of them is set.
type injectionConfig struct {
	Mode    string
	AtCount int
	LWI     string
	DelayMs int
}

func newInjectionConfig(req injectRequest) (*injectionConfig, error) {
	if !isKnownMode(req.Mode) {
		return nil, fmt.Errorf("unknown mode %q", req.Mode)
	}
	hasCount := req.AtCount != nil
	hasLWI := req.LWI != ""
	if hasCount == hasLWI {
		return nil, fmt.Errorf("exactly one of at_count or lwi must be given")
	}
	// Invocation counts are 1-indexed, so a count below 1 names an invocation
	// that cannot happen; rejecting it here keeps an armed injection that never
	// fires from being mistaken for one that fired and was not counted.
	if hasCount && *req.AtCount < 1 {
		return nil, fmt.Errorf("at_count must be >= 1")
	}
	cfg := &injectionConfig{Mode: req.Mode, LWI: req.LWI}
	if hasCount {
		cfg.AtCount = *req.AtCount
	}
	if req.DelayMs != nil {
		cfg.DelayMs = *req.DelayMs
	}
	return cfg, nil
}

// fires reports whether cfg should fire for the invocation numbered count
// (1-indexed, since the last reset) and attributed to lwi.
func (cfg *injectionConfig) fires(count int, lwi string) bool {
	if cfg == nil {
		return false
	}
	if cfg.AtCount != 0 && count == cfg.AtCount {
		return true
	}
	if cfg.LWI != "" && lwi != "" && lwi == cfg.LWI {
		return true
	}
	return false
}
