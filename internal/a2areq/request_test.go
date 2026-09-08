package a2areq

import (
	"reflect"
	"strings"
	"testing"

	"github.com/a2aproject/a2a-go/v2/a2a"
)

func TestBuild_FreshMessageIDAndWorkItemMetadata(t *testing.T) {
	req := Build("lwi-42", "hello")
	if req.Message == nil {
		t.Fatalf("message is nil")
	}
	if req.Message.ID == "" {
		t.Errorf("messageId is empty; the caller must create it")
	}
	if got := req.Message.Metadata["logical_work_item_id"]; got != "lwi-42" {
		t.Errorf("metadata.logical_work_item_id = %v, want lwi-42", got)
	}
	if req.Message.Role != a2a.MessageRoleUser {
		t.Errorf("role = %v, want %v", req.Message.Role, a2a.MessageRoleUser)
	}
	want := a2a.NewTextPart("lwi:lwi-42 hello")
	if len(req.Message.Parts) != 1 || !reflect.DeepEqual(req.Message.Parts[0].Content, want.Content) {
		t.Errorf("parts = %+v, want one text part 'lwi:lwi-42 hello'", req.Message.Parts)
	}
	other := Build("lwi-42", "hello")
	if req.Message.ID == other.Message.ID || !strings.Contains(req.Message.ID, "-") {
		t.Errorf("messageIds %q and %q should be distinct UUIDs", req.Message.ID, other.Message.ID)
	}
}

func TestBuild_NoTaskIDOnFirstMessage(t *testing.T) {
	req := Build("x", "t")
	if req.Message.TaskID != "" {
		t.Errorf("taskId = %q, want empty on a first message", req.Message.TaskID)
	}
}
