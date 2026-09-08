// Command replay is the controlled duplicate-delivery harness. It builds one
// SendMessage body from internal/a2areq, the same shape the load client sends,
// and delivers it twice over one HTTP client: byte-identical (M1), with a new
// JSON-RPC id (M2), or with a new JSON-RPC id and a new messageId (M3). It
// prints one client-ledger line per attempt.
//
// It contains no retry logic. Each attempt is exactly one http.Client.Do; a
// transport failure is recorded and reported, never repeated. The client comes
// from internal/httpclient, whose transport settings are documented and asserted
// there and again in this binary's own test.
//
// Environment:
//
//	TARGET_URL  required  where to POST (the receiver, or a port-forward to the ingress)
//	LWI         required  logical work item id, carried in Message.metadata
//	MODE        required  M1 | M2 | M3
//	TEXT        default "hello"
//	HOST        optional  Host header, for host-based routing at a gateway
//	GAP_MS      default 0 milliseconds to wait between the two attempts
//
// Exit codes of this binary: 0 both attempts got an HTTP response; 2 a required
// variable is missing or MODE is unknown; 3 a transport failure on either
// attempt; 4 a body or a ledger line could not be built.
//
// `make replay` cannot pass those through: GNU make exits 2 whenever a recipe
// fails, whatever status the recipe used, so the target returns 0 on success and
// 2 on any failure, and only its inner recipes return 0, 3 or 1. The client
// lines are the authority for what happened; a caller that needs to tell a
// transport failure from a usage error reads them, or runs this binary directly.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// clientLine is one attempt as the client saw it. The identity fields are read
// back out of the bytes that were sent, so the line describes the delivery
// rather than the intent.
type clientLine struct {
	Ledger            string `json:"ledger"`
	TS                string `json:"ts"`
	LogicalWorkItemID string `json:"logical_work_item_id"`
	Attempt           int    `json:"attempt"`
	Mode              string `json:"mode"`
	ID                string `json:"id"`
	MessageID         string `json:"messageId"`
	BodySHA256        string `json:"body_sha256"`
	Status            int    `json:"status"`
	ResultKind        string `json:"result_kind"`
	TaskID            string `json:"taskId"`
	State             string `json:"state"`
	ErrorCode         int    `json:"error_code"`
	Error             string `json:"error"`
	LatencyMs         int64  `json:"latency_ms"`
}

// sentIDs are the two identifiers read back out of a body that was sent.
type sentIDs struct {
	ID        string
	MessageID string
}

// idsOf reads the JSON-RPC id and the messageId out of a rendered body.
func idsOf(body []byte) sentIDs {
	var env struct {
		ID     string `json:"id"`
		Params struct {
			Message struct {
				MessageID string `json:"messageId"`
			} `json:"message"`
		} `json:"params"`
	}
	if json.Unmarshal(body, &env) != nil {
		return sentIDs{}
	}
	return sentIDs{ID: env.ID, MessageID: env.Params.Message.MessageID}
}

// attemptResult is one delivery: what the response said, how long it took, and
// the transport error if there was no response at all.
type attemptResult struct {
	info      responseInfo
	latencyMs int64
	err       error
}

// newClient returns the harness's HTTP client. It is internal/httpclient.New,
// named here so this binary's test can assert the transport settings directly.
func newClient(timeout time.Duration) *http.Client {
	return httpclient.New(timeout)
}

// send performs exactly one POST of body. There is no loop and no fallback: one
// call to Do, one result, whatever it was.
func send(ctx context.Context, client *http.Client, target, host string, body []byte) attemptResult {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		return attemptResult{info: responseInfo{ResultKind: "none"}, err: err}
	}
	req.Header.Set("Content-Type", "application/json")
	// The A2A version the SDKs put on the wire, set explicitly here because this
	// harness is not an SDK client; the receivers record it on the ingress ledger.
	req.Header.Set("A2A-Version", "1.0")
	if host != "" {
		// req.Host, not a Header.Set: net/http takes the authority from this field.
		req.Host = host
	}

	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return attemptResult{
			info:      responseInfo{ResultKind: "none"},
			latencyMs: time.Since(start).Milliseconds(),
			err:       err,
		}
	}
	defer func() { _ = resp.Body.Close() }()
	respBody, readErr := io.ReadAll(resp.Body)
	latency := time.Since(start).Milliseconds()
	if readErr != nil {
		// The response started and then the body was cut off. That is a delivery
		// with a status and no result, and the read error is what happened.
		info := responseInfo{Status: resp.StatusCode, ResultKind: "none", Error: readErr.Error()}
		return attemptResult{info: info, latencyMs: latency, err: readErr}
	}
	return attemptResult{info: parseResponse(resp.StatusCode, respBody), latencyMs: latency}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	target := os.Getenv("TARGET_URL")
	lwi := os.Getenv("LWI")
	mode := os.Getenv("MODE")
	if target == "" || lwi == "" || mode == "" {
		fmt.Fprintln(os.Stderr, "replay: TARGET_URL, LWI and MODE are required")
		os.Exit(2)
	}
	if !validMode(mode) {
		fmt.Fprintf(os.Stderr, "replay: MODE=%q is not one of M1, M2, M3\n", mode)
		os.Exit(2)
	}
	text := getenv("TEXT", "hello")
	host := os.Getenv("HOST")
	gapMs, gapErr := strconv.Atoi(getenv("GAP_MS", "0"))
	if gapErr != nil || gapMs < 0 {
		fmt.Fprintf(os.Stderr, "replay: GAP_MS=%q is not a non-negative integer\n", os.Getenv("GAP_MS"))
		os.Exit(2)
	}

	first, second, err := attempts(mode, lwi, text)
	if err != nil {
		fmt.Fprintf(os.Stderr, "replay: %v\n", err)
		os.Exit(4)
	}
	client := newClient(90 * time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	transportFailed := false
	for i, body := range [][]byte{first, second} {
		if i > 0 && gapMs > 0 {
			time.Sleep(time.Duration(gapMs) * time.Millisecond)
		}
		res := send(ctx, client, target, host, body)
		if res.err != nil {
			transportFailed = true
		}

		ids := idsOf(body)
		sum := sha256.Sum256(body)
		line := clientLine{
			Ledger:            "client",
			TS:                time.Now().UTC().Format(time.RFC3339Nano),
			LogicalWorkItemID: lwi,
			Attempt:           i + 1,
			Mode:              mode,
			ID:                ids.ID,
			MessageID:         ids.MessageID,
			BodySHA256:        hex.EncodeToString(sum[:]),
			Status:            res.info.Status,
			ResultKind:        res.info.ResultKind,
			TaskID:            res.info.TaskID,
			State:             res.info.State,
			ErrorCode:         res.info.ErrorCode,
			Error:             res.info.Error,
			LatencyMs:         res.latencyMs,
		}
		if res.err != nil {
			line.Error = res.err.Error()
		}
		b, marshalErr := json.Marshal(line)
		if marshalErr != nil {
			fmt.Fprintf(os.Stderr, "replay: cannot marshal the client line: %v\n", marshalErr)
			os.Exit(4)
		}
		fmt.Println(string(b))
	}

	// Both attempts are always sent: the second delivery is the measurement, and
	// a first attempt that failed at the transport is part of what is being
	// counted, not a reason to stop.
	if transportFailed {
		os.Exit(3)
	}
}
