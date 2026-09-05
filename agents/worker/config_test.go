package main

import (
	"testing"
	"time"
)

func TestModelTimeout_DefaultAndOverride(t *testing.T) {
	t.Setenv("MODEL_TIMEOUT_S", "")
	if got := modelTimeout(); got != 60*time.Second {
		t.Fatalf("default = %v, want 60s", got)
	}
	t.Setenv("MODEL_TIMEOUT_S", "5")
	if got := modelTimeout(); got != 5*time.Second {
		t.Fatalf("override = %v, want 5s", got)
	}
	t.Setenv("MODEL_TIMEOUT_S", "nonsense")
	if got := modelTimeout(); got != 60*time.Second {
		t.Fatalf("bad value = %v, want the 60s default", got)
	}
}
