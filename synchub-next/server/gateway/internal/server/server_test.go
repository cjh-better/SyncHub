package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"synchub/gateway/internal/store"
)

func TestRelayDeleteEndpoint(t *testing.T) {
	secret := []byte("fixture-relay-secret-32bytes!!")
	st, err := store.Open(t.TempDir() + "/store.json")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	cfg := Config{
		RelaySecret: secret,
		RelayWait:   time.Second,
	}
	srv := New(cfg, st)
	defer srv.Close()

	tid := "tid_del_test_123"
	if err := srv.relay.openSession(tid, "devA", "devB"); err != nil {
		t.Fatalf("openSession: %v", err)
	}

	// Sign ticket for tid
	ticket := signTicket(secret, ticketClaims{
		TID:    tid,
		Device: "devA",
		Role:   "s",
		Exp:    time.Now().Add(time.Hour).Unix(),
	})

	// Send DELETE /api/v1/relay/{tid}
	req := httptest.NewRequest("DELETE", "/api/v1/relay/"+tid, nil)
	req.Header.Set("Authorization", "Ticket "+ticket)
	rec := httptest.NewRecorder()

	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 No Content, got %d (body: %s)", rec.Code, rec.Body.String())
	}

	// Session should be purged
	if srv.relay.authorize(tid, "devA", true) {
		t.Fatal("session should be purged after DELETE")
	}
}

func TestRecordFailPruning(t *testing.T) {
	st, err := store.Open(t.TempDir() + "/store.json")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	srv := New(Config{RelaySecret: make([]byte, 32)}, st)
	defer srv.Close()

	ip := "192.168.1.100"
	// Record failures
	for i := 0; i < 5; i++ {
		srv.recordFail(ip)
	}

	srv.failMu.Lock()
	count := len(srv.fails[ip])
	srv.failMu.Unlock()

	if count != 5 {
		t.Fatalf("expected 5 failures, got %d", count)
	}
}

func TestServerNewRelayNodeAndClose(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := Config{
		Context:     ctx,
		RelaySecret: []byte("fixture-relay-secret-32bytes!!"),
		RelayWait:   time.Second,
	}
	node := NewRelayNode(cfg)
	defer node.Close()

	req := httptest.NewRequest("GET", "/healthz", nil)
	rec := httptest.NewRecorder()
	node.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("healthz expected 200, got %d", rec.Code)
	}
}
