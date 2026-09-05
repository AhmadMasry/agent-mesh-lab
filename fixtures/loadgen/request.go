package main

import (
	"github.com/a2aproject/a2a-go/v2/a2a"
)

// buildSendRequest creates the one SendMessage the load client sends for a
// work item. The client creates the messageId (a fresh UUID); the work item
// travels both as Message.metadata.logical_work_item_id and as a text token so
// the model endpoint can attribute the call even without headers.
func buildSendRequest(lwi, text string) *a2a.SendMessageRequest {
	msg := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("lwi:"+lwi+" "+text))
	msg.ID = a2a.NewMessageID()
	msg.Metadata = map[string]any{"logical_work_item_id": lwi}
	return &a2a.SendMessageRequest{Message: msg}
}
