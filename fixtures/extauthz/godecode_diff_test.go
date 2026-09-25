package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"iter"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

// Follow-on D-4, D-3b's carried review item (review-d3b.md, Minor 2): goDecode
// was pinned to a2a-go only by a hand table. This test puts generated bodies
// through a2a-go v2.5.0's own JSON-RPC handler (a2asrv.NewJSONRPCHandler, the
// handler the worker serves) with a recording RequestHandler, and holds
// goDecode to the one direction rule 4 depends on: every body the handler
// dispatches as method M, goDecode reads as M with no error. The other
// direction is not asked -- goDecode reading SubscribeToTask where the handler
// then refuses (an invalid id, a wrong jsonrpc version, bad params) is a
// refusal on the safe side. The proxy hands the fixture the body as lossy
// UTF-8 (ext_authz.rs l.442-455), so goDecode is held to it on the original
// bytes and on both lossy forms of TestGoDecoder_LossyUTF8DoesNotChangeTheAnswer.

// dispatchRecorder is an a2asrv.RequestHandler that records which method the
// handler dispatched and answers every call with an error. Nothing it does can
// be retried: it records and returns.
type dispatchRecorder struct {
	mu     sync.Mutex
	method string
}

var errRecorded = errors.New("recorded")

func (r *dispatchRecorder) got(m string) {
	r.mu.Lock()
	r.method = m
	r.mu.Unlock()
}

func (r *dispatchRecorder) take() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	m := r.method
	r.method = ""
	return m
}

func errSeq() iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) { yield(nil, errRecorded) }
}

func (r *dispatchRecorder) GetTask(context.Context, *a2a.GetTaskRequest) (*a2a.Task, error) {
	r.got("GetTask")
	return nil, errRecorded
}
func (r *dispatchRecorder) ListTasks(context.Context, *a2a.ListTasksRequest) (*a2a.ListTasksResponse, error) {
	r.got("ListTasks")
	return nil, errRecorded
}
func (r *dispatchRecorder) CancelTask(context.Context, *a2a.CancelTaskRequest) (*a2a.Task, error) {
	r.got("CancelTask")
	return nil, errRecorded
}
func (r *dispatchRecorder) SendMessage(context.Context, *a2a.SendMessageRequest) (a2a.SendMessageResult, error) {
	r.got("SendMessage")
	return nil, errRecorded
}
func (r *dispatchRecorder) SubscribeToTask(context.Context, *a2a.SubscribeToTaskRequest) iter.Seq2[a2a.Event, error] {
	r.got("SubscribeToTask")
	return errSeq()
}
func (r *dispatchRecorder) SendStreamingMessage(context.Context, *a2a.SendMessageRequest) iter.Seq2[a2a.Event, error] {
	r.got("SendStreamingMessage")
	return errSeq()
}
func (r *dispatchRecorder) GetTaskPushConfig(context.Context, *a2a.GetTaskPushConfigRequest) (*a2a.PushConfig, error) {
	r.got("GetTaskPushNotificationConfig")
	return nil, errRecorded
}
func (r *dispatchRecorder) ListTaskPushConfigs(context.Context, *a2a.ListTaskPushConfigRequest) (*a2a.ListTaskPushConfigResponse, error) {
	r.got("ListTaskPushNotificationConfigs")
	return nil, errRecorded
}
func (r *dispatchRecorder) CreateTaskPushConfig(context.Context, *a2a.PushConfig) (*a2a.PushConfig, error) {
	r.got("CreateTaskPushNotificationConfig")
	return nil, errRecorded
}
func (r *dispatchRecorder) DeleteTaskPushConfig(context.Context, *a2a.DeleteTaskPushConfigRequest) error {
	r.got("DeleteTaskPushNotificationConfig")
	return errRecorded
}
func (r *dispatchRecorder) GetExtendedAgentCard(context.Context, *a2a.GetExtendedAgentCardRequest) (*a2a.AgentCard, error) {
	r.got("GetExtendedAgentCard")
	return nil, errRecorded
}

// dispatched posts body to a2a-go's JSON-RPC handler and returns the method it
// handed to the RequestHandler, or "" when it dispatched nothing.
func dispatched(h http.Handler, rec *dispatchRecorder, body []byte) string {
	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	h.ServeHTTP(httptest.NewRecorder(), req)
	return rec.take()
}

// genBody builds one JSON-RPC-like body from parts chosen by rng: the member
// set and order, key spellings (a2a-go folds case), duplicate keys, unknown
// members at the top level and inside params, id and jsonrpc variants,
// whitespace, a leading BOM, a batch, trailing data, and truncation.
func genBody(rng *rand.Rand) []byte {
	pick := func(xs ...string) string { return xs[rng.IntN(len(xs))] }
	methods := []string{"SubscribeToTask", "SendMessage", "SendStreamingMessage", "GetTask", "CancelTask",
		"ListTasks", "subscribetotask", "SubscribeToTask ", "tasks/resubscribe", ""}
	ws := func() string { return pick("", "", " ", "\n", "\t", " \r\n ") }
	var members []string
	add := func(k, v string) { members = append(members, ws()+`"`+k+`"`+ws()+":"+ws()+v+ws()) }
	if rng.IntN(10) > 0 {
		add(pick("jsonrpc", "jsonrpc", "JSONRPC", "JsonRpc"), pick(`"2.0"`, `"2.0"`, `"2.0"`, `"1.0"`, `2`, `null`))
	}
	method := methods[rng.IntN(len(methods))]
	switch rng.IntN(12) {
	case 0: // no method
	case 1:
		add(pick("Method", "METHOD", "mEtHoD"), `"`+method+`"`)
	case 2: // duplicate: the last one wins in encoding/json
		add("method", `"`+methods[rng.IntN(len(methods))]+`"`)
		add(pick("method", "Method"), `"`+method+`"`)
	case 3:
		add("method", pick(`1`, `null`, `["SubscribeToTask"]`, `{"a":1}`))
	case 4:
		add("method", `"Subscribe\u0054oTask"`)
	default:
		add("method", `"`+method+`"`)
	}
	if rng.IntN(8) > 0 {
		add(pick("id", "id", "ID"), pick(`1`, `"r1"`, `null`, `1.5`, `-3`, `true`, `{}`, `[]`, `"`+strings.Repeat("x", 40)+`"`))
	}
	params := []string{}
	if rng.IntN(4) > 0 {
		params = append(params, `"id":"t-`+fmt.Sprint(rng.IntN(100))+`"`)
	}
	if rng.IntN(3) == 0 {
		params = append(params, `"message":{"messageId":"m1","role":"ROLE_USER","parts":[{"text":"a"}]}`)
	}
	if rng.IntN(4) == 0 {
		params = append(params, `"`+pick("x_pad", "tenant", "metadata", "Id")+`":`+pick(`"p"`, `{}`, `1`, `null`))
	}
	switch rng.IntN(8) {
	case 0: // no params
	case 1:
		add("params", pick(`[]`, `null`, `"t"`, `1`))
	default:
		add(pick("params", "params", "Params"), "{"+strings.Join(params, ",")+"}")
	}
	for n := rng.IntN(3); n > 0; n-- { // unknown top-level members, which a2a-go ignores
		add(pick("x_pad", "extra", "tenant", "jsonrpcx", "_"), pick(`"`+strings.Repeat("a", rng.IntN(20))+`"`, `{"method":"SendMessage"}`, `[1,2]`, `null`, `0`))
	}
	rng.Shuffle(len(members), func(i, j int) { members[i], members[j] = members[j], members[i] })
	body := ws() + "{" + strings.Join(members, ",") + "}" + ws()
	switch rng.IntN(14) {
	case 0:
		body = "[" + body + "]"
	case 1:
		body = utf8BOM + body
	case 2:
		body += pick("garbage", "{}", `{"method":"SendMessage"}`, "\x00", "]")
	case 3:
		body = body[:rng.IntN(len(body)+1)]
	case 4:
		i := rng.IntN(len(body) + 1)
		body = body[:i] + pick("\xff", "\xc3", "\xed\xa0\x80", "\xe2\x82", "\xff\xfe") + body[i:]
	}
	return []byte(body)
}

// lossyPerByte and lossyPerRun are the two lossy forms that bracket Rust's
// from_utf8_lossy, as in TestGoDecoder_LossyUTF8DoesNotChangeTheAnswer.
func lossyPerByte(b []byte) []byte {
	var out bytes.Buffer
	for len(b) > 0 {
		r, n := utf8.DecodeRune(b)
		if r == utf8.RuneError && n == 1 {
			out.WriteString("\uFFFD")
		} else {
			out.Write(b[:n])
		}
		b = b[n:]
	}
	return out.Bytes()
}

func lossyPerRun(b []byte) []byte { return []byte(strings.ToValidUTF8(string(b), "\uFFFD")) }

func TestGoDecoder_DifferentialAgainstA2AGoHandler(t *testing.T) {
	rec := &dispatchRecorder{}
	h := a2asrv.NewJSONRPCHandler(rec)
	rng := rand.New(rand.NewPCG(20260925, 4))
	const n = 20000
	byMethod := map[string]int{}
	unknownMemberDispatch := 0
	failures := 0
	for i := 0; i < n; i++ {
		body := genBody(rng)
		m := dispatched(h, rec, body)
		if m == "" {
			byMethod["(none)"]++
			continue
		}
		byMethod[m]++
		if bytes.Contains(body, []byte(`"x_pad"`)) || bytes.Contains(body, []byte(`"extra"`)) {
			unknownMemberDispatch++
		}
		for _, form := range []struct {
			name string
			b    []byte
		}{{"original", body}, {"lossy per byte", lossyPerByte(body)}, {"lossy per run", lossyPerRun(body)}} {
			got, err := goDecode(form.b)
			if err != nil || got != m {
				failures++
				if failures <= 20 {
					t.Errorf("a2a-go dispatched %s; goDecode on the %s body read %q, err %v; body %q", m, form.name, got, err, body)
				}
			}
		}
	}
	// The corpus must reach the cases that matter, or the test proves nothing.
	if byMethod["SubscribeToTask"] < 500 {
		t.Errorf("only %d SubscribeToTask dispatches in %d bodies", byMethod["SubscribeToTask"], n)
	}
	if unknownMemberDispatch < 200 {
		t.Errorf("only %d dispatches of bodies with an unknown member", unknownMemberDispatch)
	}
	t.Logf("%d bodies; dispatched by a2a-go v2.5.0: %v; with an unknown member: %d; disagreements: %d", n, byMethod, unknownMemberDispatch, failures)
}
