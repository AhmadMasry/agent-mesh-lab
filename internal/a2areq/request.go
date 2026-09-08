// Package a2areq builds the one SendMessage request shape this lab sends, so
// the load client and the replay harness send identical bodies for a work item
// apart from the ids they are meant to differ in.
package a2areq

import (
	"github.com/a2aproject/a2a-go/v2/a2a"
)

// Build creates one SendMessage for a work item. The caller creates the
// messageId (a fresh UUID); the work item travels both as
// Message.metadata.logical_work_item_id and as a text token, so the model
// endpoint can attribute the call even without headers. No taskId is set: this
// is a first message.
func Build(lwi, text string) *a2a.SendMessageRequest {
	msg := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("lwi:"+lwi+" "+text))
	msg.ID = a2a.NewMessageID()
	msg.Metadata = map[string]any{"logical_work_item_id": lwi}
	return &a2a.SendMessageRequest{Message: msg}
}
