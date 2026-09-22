package main

// CANCEL_AFTER_MS is the one setting Experiment B's control row (B-4, the
// author's note of 2026-09-22 in docs/proposal-notes.md) needs: the stream
// mode cancels its own request context k milliseconds after the send, so a
// task loses its only stream with no proxy event, and a second Job, a separate
// process, then sends the one SubscribeToTask.
//
// The name says what the setting does, when, and in what unit. The author's
// note asks for "cancel after k ms", and with the unit in the name a value meant
// as seconds cannot pass for milliseconds without the rendered Job saying so.
// It has no CLIENT_ prefix. Those are A.2's retry knobs and CLIENT_DIAL, which
// the unary send reads. This setting belongs with MODE, which it needs.
//
//   - Unset or empty: off. Nothing about any mode changes, and the stream
//     mode's lines carry no cancel key (TestCancel_DefaultOff,
//     TestStream_WithTheSettingOffTheLinesCarryNoCancelKey).
//   - A positive whole number k, written in decimal digits with no leading
//     zero: the stream mode cancels its request context k ms after the send,
//     counted from ts_sent, once, unless the stream has already ended.
//   - Anything else stops the Job before it sends (cancelFromEnv): zero, a
//     sign, a leading zero, a space, a unit, a fraction, an unsubstituted
//     placeholder, a number too large to read, and any k at or past the
//     process's own bound (requestBound), where the cancel could never be
//     made. So does the setting with any mode but MODE=stream. A unary send or
//     a subscription with a cancel asked for would run uncancelled and read as
//     a clean one.
//
// What the cancel is: the context.CancelFunc of the request's context, and
// nothing else. net/http then stops reading the answer and closes the
// connection. Nothing is sent: no CancelTask, no second request, no reconnect
// (rule 4, CLAUDE.md).
//
// What the end line gains, only when the setting is on (cancelFacts):
// cancel_after_ms, k; cancel_fired, whether the cancel was made while the
// stream was open; ts_cancel, the stamp taken as it was made; and
// ended_before_cancel, true when the stream had already ended before k. That
// repetition is not a control, and the process does not wait for k. Also
// events_after_cancel and kinds_after_cancel: the events the SDK handed over
// after the cancel was made, by kind and state, in order.

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
)

// cancelFromEnv reads CANCEL_AFTER_MS for a process in the given mode. Like MODE
// and CLIENT_DIAL, and unlike the A.2 retry knobs, a value it does not know is
// refused, not read as off.
func cancelFromEnv(mode clientMode) (time.Duration, error) {
	v := os.Getenv("CANCEL_AFTER_MS")
	if v == "" {
		return 0, nil
	}
	if mode != modeStream {
		return 0, fmt.Errorf("CANCEL_AFTER_MS=%q is set, but MODE=%q is not %q, the one mode that cancels; nothing was sent", v, string(mode), string(modeStream))
	}
	if !positiveDecimal(v) {
		return 0, fmt.Errorf("CANCEL_AFTER_MS=%q is not a positive whole number of milliseconds (decimal digits, no sign, no leading zero, no unit); nothing was sent", v)
	}
	k, err := strconv.ParseInt(v, 10, 64)
	if err != nil || k >= int64(requestBound/time.Millisecond) {
		return 0, fmt.Errorf("CANCEL_AFTER_MS=%q is not below the process's own bound of %d ms, so the cancel could never be made; nothing was sent", v, int64(requestBound/time.Millisecond))
	}
	return time.Duration(k) * time.Millisecond, nil
}

func positiveDecimal(v string) bool {
	if v == "" || v[0] < '1' || v[0] > '9' {
		return false
	}
	for i := 1; i < len(v); i++ {
		if v[i] < '0' || v[i] > '9' {
			return false
		}
	}
	return true
}

// cancelFacts is what the end line says about the cancel. It is embedded in
// streamEnd as a pointer, which encoding/json leaves out entirely when nil: with
// the setting off the end line has exactly the keys B-3 recorded.
type cancelFacts struct {
	CancelAfterMS     int64    `json:"cancel_after_ms"`
	CancelFired       bool     `json:"cancel_fired"`
	TSCancel          string   `json:"ts_cancel"`
	EndedBeforeCancel bool     `json:"ended_before_cancel"`
	EventsAfterCancel int      `json:"events_after_cancel"`
	KindsAfterCancel  []string `json:"kinds_after_cancel"`
}

// canceller makes the stream mode's one cancel. start arms a timer for after.
// fire, from that timer, cancels the request context unless the stream has
// ended. sawEvent records an event the SDK handed over after the cancel. stop
// marks the stream ended, disarms the timer and returns the facts. A nil
// canceller is the setting off: every method does nothing and stop returns nil.
type canceller struct {
	after  time.Duration
	cancel context.CancelFunc

	mu      sync.Mutex
	timer   *time.Timer
	ended   bool
	fired   bool
	firedAt time.Time
	kinds   []string
}

func (c *canceller) start() {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.timer = time.AfterFunc(c.after, c.fire)
}

// fire makes the cancel, once, while the stream is open. The stamp is taken and
// the flag set before the context is cancelled, so any event the SDK hands over
// from then on is counted as after the cancel.
func (c *canceller) fire() {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.ended || c.fired {
		c.mu.Unlock()
		return
	}
	c.fired = true
	c.firedAt = time.Now()
	c.mu.Unlock()
	c.cancel()
}

func (c *canceller) sawEvent(kind, state string) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.fired {
		return
	}
	if state != "" {
		kind += "/" + state
	}
	c.kinds = append(c.kinds, kind)
}

func (c *canceller) stop() *cancelFacts {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ended = true
	if c.timer != nil {
		c.timer.Stop()
	}
	f := &cancelFacts{CancelAfterMS: int64(c.after / time.Millisecond), CancelFired: c.fired, EndedBeforeCancel: !c.fired,
		EventsAfterCancel: len(c.kinds), KindsAfterCancel: append([]string{}, c.kinds...)}
	if c.fired {
		f.TSCancel = c.firedAt.UTC().Format(time.RFC3339Nano)
	}
	return f
}
