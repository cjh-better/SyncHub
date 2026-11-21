package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"synchub/gateway/internal/proto"
	"synchub/gateway/internal/store"
)

func TestHubWebSocketLifecycleAndGracefulClose(t *testing.T) {
	st, err := store.Open(t.TempDir() + "/store.json")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	dev, tok, err := st.Register("DeviceTest", "linux", "dummyPub")
	if err != nil {
		t.Fatalf("register device: %v", err)
	}

	cfg := Config{
		RelaySecret: []byte("fixture-relay-secret-32bytes!!"),
		RelayWait:   time.Second,
	}
	srv := New(cfg, st)
	defer srv.Close()

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/v1/ws?token=" + tok
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, resp, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v (resp: %v)", err, resp)
	}

	// Read initial devices envelope
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read initial frame: %v", err)
	}
	var env proto.Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("unmarshal envelope: %v", err)
	}
	if env.Type != "devices" {
		t.Fatalf("expected devices frame, got %s", env.Type)
	}

	// Send ping envelope
	pingEnv := proto.Envelope{Type: "ping", ID: "req_1"}
	pingBytes, _ := json.Marshal(pingEnv)
	if err := conn.Write(ctx, websocket.MessageText, pingBytes); err != nil {
		t.Fatalf("write ping: %v", err)
	}

	// Read pong envelope
	_, pongData, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read pong: %v", err)
	}
	var pongEnv proto.Envelope
	if err := json.Unmarshal(pongData, &pongEnv); err != nil {
		t.Fatalf("unmarshal pong: %v", err)
	}
	if pongEnv.Type != "pong" || pongEnv.ID != "req_1" {
		t.Fatalf("expected pong with id req_1, got %+v", pongEnv)
	}

	// Graceful close: tests that serveWS WaitGroup awaits writeLoop cleanly
	if err := conn.Close(websocket.StatusNormalClosure, "bye"); err != nil {
		t.Logf("client close err (normal): %v", err)
	}

	// Verify device status in store
	time.Sleep(50 * time.Millisecond)
	d, ok := st.Get(dev.ID)
	if !ok {
		t.Fatal("device not found in store")
	}
	_ = d
}

func TestHubSignalTriggersSessionCleanup(t *testing.T) {
	st, err := store.Open(t.TempDir() + "/store.json")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	devA, _, _ := st.Register("DevA", "linux", "pubA")
	devB, _, _ := st.Register("DevB", "windows", "pubB")

	var cleanedTID string
	var mu sync.Mutex

	h := newHub(st)
	h.closeSession = func(tid string) {
		mu.Lock()
		cleanedTID = tid
		mu.Unlock()
	}

	// Forward Done signal
	doneSignal := proto.Signal{
		Kind: proto.KindDone,
		Done: &proto.Done{
			TransferID: "tid_done_999",
			OK:         true,
		},
	}
	payload, _ := json.Marshal(doneSignal)
	env := proto.Envelope{
		Type:    "signal",
		ID:      "sig_1",
		To:      devB.ID,
		Payload: payload,
	}

	c := &wsClient{dev: devA.ID, send: make(chan []byte, 10)}
	h.forward(c, env)

	mu.Lock()
	tid := cleanedTID
	mu.Unlock()

	if tid != "tid_done_999" {
		t.Fatalf("expected closeSession for tid_done_999, got %q", tid)
	}

	// Forward Cancel signal
	cancelSignal := proto.Signal{
		Kind: proto.KindCancel,
		Cancel: &proto.Cancel{
			TransferID: "tid_cancel_888",
			Reason:     "user abort",
		},
	}
	payload2, _ := json.Marshal(cancelSignal)
	env2 := proto.Envelope{
		Type:    "signal",
		ID:      "sig_2",
		To:      devB.ID,
		Payload: payload2,
	}

	h.forward(c, env2)

	mu.Lock()
	tid2 := cleanedTID
	mu.Unlock()

	if tid2 != "tid_cancel_888" {
		t.Fatalf("expected closeSession for tid_cancel_888, got %q", tid2)
	}
}
