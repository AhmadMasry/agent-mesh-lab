// Command loadgen sends exactly one A2A SendMessage with the a2a-go client and
// prints one client-ledger line. It contains no retry logic: the a2a-go client
// has no retry option, and the HTTP client comes from internal/httpclient.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	"github.com/a2aproject/a2a-go/v2/a2aclient/agentcard"

	"github.com/AhmadMasry/agent-mesh-lab/internal/a2areq"
	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

type clientLine struct {
	Ledger               string   `json:"ledger"`
	TS                   string   `json:"ts"`
	LogicalWorkItemID    string   `json:"logical_work_item_id"`
	MessageID            string   `json:"messageId"`
	TaskID               string   `json:"taskId"`
	ResultKind           string   `json:"result_kind"`
	State                string   `json:"state"`
	A2AVersion           string   `json:"a2a_version"`
	CardProtocolVersions []string `json:"card_protocol_versions"`
	Error                string   `json:"error,omitempty"`
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
	if target == "" || lwi == "" {
		fmt.Fprintln(os.Stderr, "loadgen: TARGET_URL and LWI are required")
		os.Exit(2)
	}
	text := getenv("TEXT", "hello")
	line := clientLine{Ledger: "client", LogicalWorkItemID: lwi, A2AVersion: string(a2a.Version)}
	emit := func() {
		line.TS = time.Now().UTC().Format(time.RFC3339Nano)
		b, _ := json.Marshal(line)
		fmt.Println(string(b))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	hc := httpclient.New(90 * time.Second)

	card, err := agentcard.NewResolver(hc).Resolve(ctx, target)
	if err != nil {
		line.Error = "resolve card: " + err.Error()
		emit()
		os.Exit(3)
	}
	for _, iface := range card.SupportedInterfaces {
		line.CardProtocolVersions = append(line.CardProtocolVersions, string(iface.ProtocolVersion))
	}
	client, err := a2aclient.NewFromCard(ctx, card, a2aclient.WithDefaultsDisabled(), a2aclient.WithJSONRPCTransport(hc))
	if err != nil {
		line.Error = "create client: " + err.Error()
		emit()
		os.Exit(3)
	}

	req := a2areq.Build(lwi, text)
	line.MessageID = req.Message.ID
	res, err := client.SendMessage(ctx, req)
	if err != nil {
		// A failed request is a recorded outcome; the process still exits non-zero
		// only because no result object exists to describe.
		line.Error = err.Error()
		emit()
		os.Exit(3)
	}
	switch r := res.(type) {
	case *a2a.Task:
		line.ResultKind = "task"
		line.TaskID = string(r.ID)
		line.State = string(r.Status.State)
	case *a2a.Message:
		line.ResultKind = "message"
		line.TaskID = string(r.TaskID)
	default:
		line.ResultKind = fmt.Sprintf("%T", res)
	}
	emit()
}
