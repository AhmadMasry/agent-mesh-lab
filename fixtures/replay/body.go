package main

import (
	"encoding/json"
	"fmt"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/google/uuid"

	"github.com/AhmadMasry/agent-mesh-lab/internal/a2areq"
)

// clientRequest is the JSON-RPC envelope a2a-go's client puts on the wire. The
// SDK's own type is internal (a2a-go/v2/internal/jsonrpc.ClientRequest, v2.5.0),
// so the field set, the tags, and the field order are mirrored here; the payload
// is the SDK's own *a2a.SendMessageRequest, marshalled by the SDK's own tags.
// testdata/go-client-body.json is the recorded wire body this reproduces, and
// TestBuildBody_MatchesRecordedA2AGoClientEnvelope compares the bytes.
type clientRequest struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
	ID      string `json:"id"`
}

const (
	// jsonRPCVersion and methodSendMessage match a2a-go's jsonrpc.Version and
	// jsonrpc.MethodMessageSend at v2.5.0.
	jsonRPCVersion    = "2.0"
	methodSendMessage = "SendMessage"

	modeM1 = "M1"
	modeM2 = "M2"
	modeM3 = "M3"
)

// validMode reports whether m names one of the three duplicate-delivery modes.
func validMode(m string) bool {
	return m == modeM1 || m == modeM2 || m == modeM3
}

// buildBody renders one SendMessage body with the two ids given, so the same
// bytes can be produced twice. Everything except the ids comes from
// internal/a2areq.Build, the one request shape this lab sends. A marshal
// failure is returned rather than handled here: the payload is a fixed struct
// of strings and maps of strings, so a failure means the SDK's types changed
// shape, which is a finding, and main owns the exit policy.
func buildBody(id, messageID, lwi, text string) ([]byte, error) {
	req := a2areq.Build(lwi, text)
	req.Message.ID = messageID
	b, err := json.Marshal(clientRequest{
		JSONRPC: jsonRPCVersion,
		Method:  methodSendMessage,
		Params:  req,
		ID:      id,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal the request body: %w", err)
	}
	return b, nil
}

// attempts renders the two bodies of one replay, from a single template, so the
// only difference between them is the one the mode names:
//
//	M1  the same JSON-RPC id and the same messageId: byte-identical redelivery
//	M2  a new JSON-RPC id, the same messageId: a new request carrying a message
//	    identity the receiver has already seen
//	M3  a new JSON-RPC id and a new messageId: a second message for the same
//	    logical work item
//
// The logical work item and the text are the same in all three. mode must be one
// of the three; callers validate it with validMode first, and an unknown mode
// returns no bodies rather than a silently wrong pair.
func attempts(mode, lwi, text string) (first, second []byte, err error) {
	// The JSON-RPC id is a v4 UUID and the messageId a v7 UUID, which is what
	// a2a-go's client generates for each (uuid.NewString and a2a.NewMessageID).
	id := uuid.NewString()
	messageID := a2a.NewMessageID()
	if first, err = buildBody(id, messageID, lwi, text); err != nil {
		return nil, nil, err
	}
	switch mode {
	case modeM1:
		second, err = buildBody(id, messageID, lwi, text)
	case modeM2:
		second, err = buildBody(uuid.NewString(), messageID, lwi, text)
	case modeM3:
		second, err = buildBody(uuid.NewString(), a2a.NewMessageID(), lwi, text)
	default:
		return nil, nil, fmt.Errorf("unknown mode %q", mode)
	}
	if err != nil {
		return nil, nil, err
	}
	return first, second, nil
}
