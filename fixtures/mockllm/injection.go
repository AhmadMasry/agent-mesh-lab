package main

import "fmt"

const (
	modeHTTP500        = "http500"
	modeClose          = "close"
	modeDelayThenClose = "delay-then-close"
	modeStale          = "stale"
)

func isKnownMode(mode string) bool {
	switch mode {
	case modeHTTP500, modeClose, modeDelayThenClose, modeStale:
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
