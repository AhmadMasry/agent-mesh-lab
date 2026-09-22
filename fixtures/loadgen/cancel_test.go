package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// Experiment B's control row (B-4): the stream mode cancels its own request
// context CANCEL_AFTER_MS after the send, once, and the end line says so. These
// tests pin that the setting is off unless asked for, that it is refused
// wherever it would not be the row it is recorded as, that the cancel ends the
// one stream and sends nothing after it, and what the end line says about it.

// The setting is off unless the environment names a value: unset and empty both
// leave every mode as it was. The Job template renders CANCEL_AFTER_MS empty on
// every row that is not a B-4 row, so this is the test that keeps those rows
// what they were.
func TestCancel_DefaultOff(t *testing.T) {
	for _, mode := range []clientMode{modeUnary, modeStream, modeSubscribe} {
		for _, set := range []bool{false, true} {
			if set {
				t.Setenv("CANCEL_AFTER_MS", "")
			} else {
				t.Setenv("CANCEL_AFTER_MS", "x")
				unsetenv(t, "CANCEL_AFTER_MS")
			}
			after, err := cancelFromEnv(mode)
			if err != nil || after != 0 {
				t.Errorf("MODE=%q set-empty=%v: got %v, %v; want off and no error", mode, set, after, err)
			}
		}
	}
}

// A positive whole number of milliseconds is the one form accepted, and only in
// the stream mode.
func TestCancelFromEnv_APositiveWholeNumberOfMillisecondsInStreamMode(t *testing.T) {
	for v, want := range map[string]time.Duration{
		"1":      time.Millisecond,
		"2500":   2500 * time.Millisecond,
		"119999": 119999 * time.Millisecond,
	} {
		t.Setenv("CANCEL_AFTER_MS", v)
		got, err := cancelFromEnv(modeStream)
		if err != nil || got != want {
			t.Errorf("CANCEL_AFTER_MS=%q: got %v, %v; want %v", v, got, err, want)
		}
	}
}

// Anything else stops the Job before it sends. A value read as off would run an
// uncancelled stream that reads as a clean one, and a value read some other way
// would cancel at a time nobody asked for. A k at or past the process's own
// 2-minute bound is refused too: that cancel could never be made.
func TestCancelFromEnv_AnythingElseIsRefused(t *testing.T) {
	for _, v := range []string{"0", "00", "-1", "+5", "05", " 5", "5 ", "5ms", "5s", "1.5", "1e3", "0x10", "soon", "on",
		"${CANCEL_AFTER_MS}", "99999999999999999999", "120000", "300000"} {
		t.Setenv("CANCEL_AFTER_MS", v)
		_, err := cancelFromEnv(modeStream)
		if err == nil || !strings.Contains(err.Error(), fmt.Sprintf("%q", v)) {
			t.Errorf("CANCEL_AFTER_MS=%q: got %v, want a refusal that names the value", v, err)
		}
	}
}

// The setting belongs to the stream mode. With the unary send or a
// subscription it would run uncancelled and be recorded as a row that
// cancelled, so either is refused, a well-formed value included.
func TestCancelFromEnv_RefusedWithAnyModeButStream(t *testing.T) {
	for _, mode := range []clientMode{modeUnary, modeSubscribe} {
		for _, v := range []string{"2500", "${CANCEL_AFTER_MS}"} {
			t.Setenv("CANCEL_AFTER_MS", v)
			if _, err := cancelFromEnv(mode); err == nil {
				t.Errorf("MODE=%q with CANCEL_AFTER_MS=%q was accepted", mode, v)
			}
		}
	}
}

// main's opening refuses what cancelFromEnv refuses, and carries what it
// accepts: the setting is wired in, not only written.
func TestConfigFromEnv_TheCancelSettingIsWiredIn(t *testing.T) {
	base := map[string]string{"TARGET_URL": "http://t.example:8080", "LWI": "lwi-1", "CLIENT_DIAL": "",
		"MODE": "", "TASK_ID": "", "CLIENT_RETRIES": "", "CLIENT_SDK_RESEND": "", "CLIENT_RETRY_ON": "", "TEXT": "",
		"CANCEL_AFTER_MS": ""}
	setAll := func(over map[string]string) {
		for k, v := range base {
			t.Setenv(k, v)
		}
		for k, v := range over {
			t.Setenv(k, v)
		}
	}
	for _, tc := range []struct {
		over map[string]string
		want time.Duration
	}{
		{map[string]string{"MODE": "stream"}, 0},
		{map[string]string{"MODE": "stream", "CANCEL_AFTER_MS": "2500"}, 2500 * time.Millisecond},
	} {
		setAll(tc.over)
		c, _, err := configFromEnv()
		if err != nil || c.mode.mode != modeStream || c.cancelAfter != tc.want {
			t.Errorf("%v: got cancelAfter %v, mode %q, %v; want %v", tc.over, c.cancelAfter, c.mode.mode, err, tc.want)
		}
	}
	for name, over := range map[string]map[string]string{
		"a cancel on the unary send":       {"CANCEL_AFTER_MS": "2500"},
		"a cancel on a subscription":       {"MODE": "subscribe", "TASK_ID": "task-9", "CANCEL_AFTER_MS": "2500"},
		"a cancel that is not a number":    {"MODE": "stream", "CANCEL_AFTER_MS": "soon"},
		"a cancel that is zero":            {"MODE": "stream", "CANCEL_AFTER_MS": "0"},
		"a placeholder left, stream":       {"MODE": "stream", "CANCEL_AFTER_MS": "${CANCEL_AFTER_MS}"},
		"a placeholder left, unary":        {"CANCEL_AFTER_MS": "${CANCEL_AFTER_MS}"},
		"a cancel past the process' bound": {"MODE": "stream", "CANCEL_AFTER_MS": "120000"},
	} {
		setAll(over)
		if _, _, err := configFromEnv(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// runConfigLines runs one process's worth of runMode with c, and returns the
// exit status, the client lines and how long the process's request took.
func runConfigLines(t *testing.T, hc *http.Client, c runConfig) (int, []map[string]any, time.Duration) {
	t.Helper()
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	start := time.Now()
	code := runMode(ctx, hc, c, &out)
	took := time.Since(start)
	return code, parseLines(t, out.String()), took
}

func parseLines(t *testing.T, raw string) []map[string]any {
	t.Helper()
	var lines []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(raw), "\n") {
		if l == "" {
			continue
		}
		var line map[string]any
		if err := json.Unmarshal([]byte(l), &line); err != nil {
			t.Fatalf("client line is not JSON: %v: %s", err, l)
		}
		lines = append(lines, line)
	}
	return lines
}

// heldStream is a stream that sends the submitted Task and WORKING, then stays
// open until the client goes away or hold passes, and records when the client
// went. Left alone for hold it completes, so a cancel that was never made shows
// as a clean stream.
type heldStream struct {
	mu   sync.Mutex
	gone time.Time
}

func (h *heldStream) clientGone() time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.gone
}

func holdOpen(t *testing.T, hold time.Duration, h *heldStream) func(http.ResponseWriter, *http.Request, rpcSeen) {
	return func(w http.ResponseWriter, r *http.Request, rpc rpcSeen) {
		sseStart(w)
		sseEvent(t, w, rpc.id, taskEvent(a2a.TaskStateSubmitted))
		sseEvent(t, w, rpc.id, statusEvent(a2a.TaskStateWorking))
		select {
		case <-r.Context().Done():
			h.mu.Lock()
			h.gone = time.Now()
			h.mu.Unlock()
		case <-time.After(hold):
			sseEvent(t, w, rpc.id, artifactEvent())
			sseEvent(t, w, rpc.id, statusEvent(a2a.TaskStateCompleted))
		}
	}
}

func stampOf(t *testing.T, line map[string]any, key string) time.Time {
	t.Helper()
	s, _ := line[key].(string)
	ts, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		t.Fatalf("%s %q does not parse: %v (line %v)", key, s, err, line)
	}
	return ts
}

// The control's one stimulus: the stream is cancelled k after the send, while
// it is open. The one POST ends there, the server sees the client go, and
// nothing is sent after it -- no stream again, no subscription, no CancelTask.
// The end line says the client cancelled, when, and that no event came after.
func TestStream_CancelAfterKEndsTheOneStreamAndSendsNothingMore(t *testing.T) {
	held := &heldStream{}
	srv := newScriptedServer(t, true, holdOpen(t, 5*time.Second, held))
	k := 300 * time.Millisecond
	code, lines, took := runConfigLines(t, streamClientForTest(), runConfig{target: srv.URL, workItem: "lwi-b4", text: "hello",
		mode: modeConfig{mode: modeStream}, cancelAfter: k})
	if code != 3 {
		t.Errorf("exit status %d, want 3: a cancelled stream ends without a terminal event", code)
	}
	if took >= 3*time.Second {
		t.Errorf("the request took %v: the cancel at %v did not end it; the server held it open for 5 s", took, k)
	}
	// Give a would-be second request time to arrive before counting.
	time.Sleep(300 * time.Millisecond)
	gets, posts := srv.seen()
	if gets != 1 || len(posts) != 1 || posts[0].method != "SendStreamingMessage" {
		t.Errorf("server saw %d GET and %d POSTs %v; want the card GET and the one SendStreamingMessage", gets, len(posts), methodsOf(posts))
	}
	if held.clientGone().IsZero() {
		t.Errorf("the server never saw the client go")
	}

	end := theEnd(t, lines)
	wantField(t, end, "cancel_after_ms", float64(300))
	wantField(t, end, "cancel_fired", true)
	wantField(t, end, "ended_before_cancel", false)
	wantField(t, end, "events_after_cancel", float64(0))
	wantField(t, end, "kinds_after_cancel", []any{})
	wantField(t, end, "events", float64(2))
	wantField(t, end, "last_state", "TASK_STATE_WORKING")
	wantField(t, end, "terminal_seen", false)
	wantField(t, end, "stream_end", "error")
	if msg, _ := end["error"].(string); !strings.Contains(msg, context.Canceled.Error()) {
		t.Errorf("error = %q, want the SDK's text for the cancelled context", msg)
	}
	wantField(t, end, "posts", float64(1))
	sent, cancelled := stampOf(t, end, "ts_sent"), stampOf(t, end, "ts_cancel")
	if d := cancelled.Sub(sent); d < k || d > k+time.Second {
		t.Errorf("the cancel came %v after the send, want %v (and under a second more)", d, k)
	}
	if gone := held.clientGone(); !gone.IsZero() && gone.Before(cancelled) {
		t.Errorf("the server saw the client go at %v, before the cancel at %v", gone, cancelled)
	}
}

// A stream that ends before k is not a control: no cancel is made, the end line
// says the stream had ended first, and the process does not wait for k.
func TestStream_AStreamThatEndsBeforeKSaysItWasNotCancelled(t *testing.T) {
	srv := newScriptedServer(t, true, theWholeTask(t))
	k := 2 * time.Second
	code, lines, took := runConfigLines(t, streamClientForTest(), runConfig{target: srv.URL, workItem: "lwi-b4", text: "hello",
		mode: modeConfig{mode: modeStream}, cancelAfter: k})
	if code != 0 {
		t.Errorf("exit status %d, want 0: the stream completed", code)
	}
	if took >= k {
		t.Errorf("the request took %v: the process waited for the cancel at %v after the stream had ended", took, k)
	}
	end := theEnd(t, lines)
	wantField(t, end, "cancel_after_ms", float64(2000))
	wantField(t, end, "cancel_fired", false)
	wantField(t, end, "ts_cancel", "")
	wantField(t, end, "ended_before_cancel", true)
	wantField(t, end, "events_after_cancel", float64(0))
	wantField(t, end, "kinds_after_cancel", []any{})
	wantField(t, end, "events", float64(4))
	wantField(t, end, "terminal_seen", true)
	wantField(t, end, "stream_end", "eof")
	if _, posts := srv.seen(); len(posts) != 1 {
		t.Errorf("server saw %d POSTs %v, want 1", len(posts), methodsOf(posts))
	}
}

// Which events the SDK handed over after the cancel is read from the loop
// itself: an iterator that yields two events, has the cancel made, and yields
// two more and then the cancelled context's error, is recorded as two events
// after the cancel, by kind and state, in order. Over a socket that order
// depends on what the SDK had already read, so it is pinned here.
func TestStream_EventsHandedOverAfterTheCancelAreNamed(t *testing.T) {
	calls := 0
	cx := &canceller{after: time.Hour, cancel: func() { calls++ }}
	var firedBy time.Time
	events := func(yield func(a2a.Event, error) bool) {
		if !yield(taskEvent(a2a.TaskStateSubmitted), nil) || !yield(statusEvent(a2a.TaskStateWorking), nil) {
			return
		}
		cx.fire()
		firedBy = time.Now()
		if !yield(artifactEvent(), nil) || !yield(statusEvent(a2a.TaskStateCompleted), nil) {
			return
		}
		yield(nil, context.Canceled)
	}
	var out bytes.Buffer
	end := streamEnd{Mode: string(modeStream), Method: "SendStreamingMessage"}
	err := readEvents(events, runConfig{workItem: "lwi-b4", mode: modeConfig{mode: modeStream}}, "SendStreamingMessage", &end, cx, nil, &out)
	// ts_cancel is the moment the cancel was made, not the moment the stream's
	// end was noticed: a gap before stop must not move it.
	time.Sleep(50 * time.Millisecond)
	f := cx.stop()
	if !errors.Is(err, context.Canceled) {
		t.Errorf("readEvents returned %v, want the iterator's error", err)
	}
	if calls != 1 {
		t.Errorf("the cancel function ran %d times, want once", calls)
	}
	if end.Events != 4 || len(linesOf(parseLines(t, out.String()), "event")) != 4 {
		t.Errorf("events = %d, event lines %d; want 4 and 4", end.Events, len(linesOf(parseLines(t, out.String()), "event")))
	}
	if f == nil {
		t.Fatal("no cancel facts from a canceller that was on")
	}
	want := cancelFacts{CancelAfterMS: int64(time.Hour / time.Millisecond), CancelFired: true, EventsAfterCancel: 2,
		KindsAfterCancel: []string{"artifact-update", "status-update/TASK_STATE_COMPLETED"}}
	got := *f
	if at, perr := time.Parse(time.RFC3339Nano, got.TSCancel); perr != nil {
		t.Errorf("ts_cancel %q does not parse: %v", got.TSCancel, perr)
	} else if at.After(firedBy) {
		t.Errorf("ts_cancel %v is after the cancel had been made (%v): it was stamped later", at, firedBy)
	}
	got.TSCancel = ""
	if !reflect.DeepEqual(got, want) {
		t.Errorf("facts = %+v, want %+v", got, want)
	}
}

// Once the stream has ended, the cancel is not made: a timer that fires after
// the end runs no cancel and the facts say the stream ended first. The
// canceller of a stream without the setting is nil, and is off everywhere.
func TestCanceller_AfterTheStreamEndedTheCancelIsNotMade(t *testing.T) {
	calls := 0
	cx := &canceller{after: time.Hour, cancel: func() { calls++ }}
	f := cx.stop()
	cx.fire()
	if calls != 0 {
		t.Errorf("the cancel function ran %d times after the stream ended, want 0", calls)
	}
	if f == nil || f.CancelFired || !f.EndedBeforeCancel || f.TSCancel != "" || f.EventsAfterCancel != 0 ||
		f.KindsAfterCancel == nil || len(f.KindsAfterCancel) != 0 {
		t.Errorf("facts = %+v, want not fired, ended before the cancel, no stamp, an empty list", f)
	}
	var off *canceller
	off.start()
	off.fire()
	off.sawEvent("task", "TASK_STATE_WORKING")
	if off.stop() != nil {
		t.Errorf("a nil canceller gave facts; with the setting off the end line carries none")
	}
}

// With the setting off the stream mode's lines are the ones B-3 recorded: the
// same keys on the end line and on each event line, and no cancel key.
func TestStream_WithTheSettingOffTheLinesCarryNoCancelKey(t *testing.T) {
	srv := newScriptedServer(t, true, theWholeTask(t))
	_, lines, _ := runConfigLines(t, streamClientForTest(), runConfig{target: srv.URL, workItem: "lwi-b4", text: "hello",
		mode: modeConfig{mode: modeStream}})
	wantEnd := []string{"ledger", "ts", "mode", "method", "line", "logical_work_item_id", "messageId", "taskId",
		"requested_task_id", "ts_sent", "events", "first_kind", "first_state", "first_task_id", "last_kind", "last_state",
		"terminal_seen", "stream_end", "error", "http_status", "content_type", "wire_error_code", "wire_error_message",
		"posts", "a2a_version", "card_protocol_versions", "card_streaming", "advertised_urls", "dialled_url"}
	wantEvent := []string{"ledger", "ts", "mode", "method", "line", "seq", "logical_work_item_id", "messageId", "taskId",
		"contextId", "kind", "state"}
	if keys := keysOf(theEnd(t, lines)); !sameSet(keys, wantEnd) {
		t.Errorf("end line keys = %v, want B-3's %v", keys, wantEnd)
	}
	for _, e := range linesOf(lines, "event") {
		if keys := keysOf(e); !sameSet(keys, wantEvent) {
			t.Errorf("event line keys = %v, want B-3's %v", keys, wantEvent)
		}
	}
}

func keysOf(line map[string]any) []string {
	var keys []string
	for k := range line {
		keys = append(keys, k)
	}
	return keys
}

// The unary send never reads the setting, not even from the environment: with
// CANCEL_AFTER_MS set in the process, a SendMessage answered after 300 ms still
// gets its answer. configFromEnv refuses the combination before this could run;
// this test is what fails if the unary path starts to read it on its own.
func TestCancel_TheUnarySendDoesNotReadTheSetting(t *testing.T) {
	t.Setenv("CANCEL_AFTER_MS", "1")
	srv := newScriptedServer(t, false, func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		time.Sleep(300 * time.Millisecond)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(rpc.id) +
			`,"result":{"task":{"id":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`))
	})
	code, lines, _ := runConfigLines(t, instrument(httpclient.New(10*time.Second), "lwi-b4"),
		runConfig{target: srv.URL, workItem: "lwi-b4", text: "hello", mode: modeConfig{mode: modeUnary}})
	if code != 0 || len(lines) != 1 {
		t.Fatalf("exit status %d, lines %v; want 0 and the one unary line", code, lines)
	}
	wantField(t, lines[0], "result_kind", "task")
	wantField(t, lines[0], "state", "TASK_STATE_COMPLETED")
	if _, ok := lines[0]["error"]; ok {
		t.Errorf("the unary send recorded an error: %v", lines[0])
	}
}
