package server

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestRelayPairing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := newRelay(ctx, 2*time.Second)
	defer r.Close()

	payload := []byte("hello relay chunk streaming")
	key := "test-tid/sess/0/0"

	var wg sync.WaitGroup
	wg.Add(2)

	var getRec *httptest.ResponseRecorder
	var putRec *httptest.ResponseRecorder

	// Receiver GET
	go func() {
		defer wg.Done()
		req := httptest.NewRequest("GET", "/chunk", nil)
		getRec = httptest.NewRecorder()
		r.get(getRec, req, key)
	}()

	// Small pause to let receiver park
	time.Sleep(20 * time.Millisecond)

	// Sender PUT
	go func() {
		defer wg.Done()
		req := httptest.NewRequest("PUT", "/chunk", bytes.NewReader(payload))
		req.ContentLength = int64(len(payload))
		putRec = httptest.NewRecorder()
		r.put(putRec, req, key)
	}()

	wg.Wait()

	if putRec.Code != http.StatusNoContent {
		t.Fatalf("PUT expected 204 No Content, got %d", putRec.Code)
	}
	if getRec.Code != http.StatusOK {
		t.Fatalf("GET expected 200 OK, got %d", getRec.Code)
	}
	if !bytes.Equal(getRec.Body.Bytes(), payload) {
		t.Fatalf("GET body mismatch: expected %q, got %q", payload, getRec.Body.String())
	}
}

func TestRelayInterruptedStream(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := newRelay(ctx, 2*time.Second)
	defer r.Close()

	key := "test-tid-interrupted/sess/0/0"
	var wg sync.WaitGroup
	wg.Add(2)

	var getRec *httptest.ResponseRecorder
	var putRec *httptest.ResponseRecorder

	// Receiver GET
	go func() {
		defer wg.Done()
		req := httptest.NewRequest("GET", "/chunk", nil)
		getRec = httptest.NewRecorder()
		r.get(getRec, req, key)
	}()

	time.Sleep(20 * time.Millisecond)

	// Sender PUT claims 100 bytes but only provides 10 bytes (interrupted)
	go func() {
		defer wg.Done()
		req := httptest.NewRequest("PUT", "/chunk", bytes.NewReader([]byte("short data")))
		req.ContentLength = 100 // claims 100 bytes
		putRec = httptest.NewRecorder()
		r.put(putRec, req, key)
	}()

	wg.Wait()

	// Sender should get 502 Bad Gateway
	if putRec.Code != http.StatusBadGateway {
		t.Fatalf("PUT expected 502 Bad Gateway on truncated stream, got %d", putRec.Code)
	}
	// Receiver must get 502 Bad Gateway, NOT a premature 200 OK with truncated body
	if getRec.Code != http.StatusBadGateway {
		t.Fatalf("GET expected 502 Bad Gateway, got %d (body: %s)", getRec.Code, getRec.Body.String())
	}
}

func TestRelayWaiterCancellationNoLoss(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := newRelay(ctx, 500*time.Millisecond)
	defer r.Close()

	key := "test-tid-cancel/sess/0/0"

	// Receiver 1 registers with short context and times out/cancels
	ctx1, cancel1 := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel1()
	req1 := httptest.NewRequestWithContext(ctx1, "GET", "/chunk", nil)
	rec1 := httptest.NewRecorder()
	r.get(rec1, req1, key)

	// Receiver 1 should have exited
	if rec1.Code != http.StatusGatewayTimeout && rec1.Code != 0 && ctx1.Err() == nil {
		t.Fatalf("unexpected code for receiver 1: %d", rec1.Code)
	}

	// Receiver 2 registers for the same chunk key
	var wg sync.WaitGroup
	wg.Add(2)

	payload := []byte("data for receiver 2")
	var rec2 *httptest.ResponseRecorder
	var putRec *httptest.ResponseRecorder

	go func() {
		defer wg.Done()
		req2 := httptest.NewRequest("GET", "/chunk", nil)
		rec2 = httptest.NewRecorder()
		r.get(rec2, req2, key)
	}()

	time.Sleep(20 * time.Millisecond)

	go func() {
		defer wg.Done()
		req := httptest.NewRequest("PUT", "/chunk", bytes.NewReader(payload))
		req.ContentLength = int64(len(payload))
		putRec = httptest.NewRecorder()
		r.put(putRec, req, key)
	}()

	wg.Wait()

	// Receiver 2 must successfully receive the chunk without being dropped or lost
	if rec2.Code != http.StatusOK {
		t.Fatalf("Receiver 2 expected 200 OK, got %d (body: %s)", rec2.Code, rec2.Body.String())
	}
	if !bytes.Equal(rec2.Body.Bytes(), payload) {
		t.Fatalf("Receiver 2 body mismatch: got %q, want %q", rec2.Body.String(), payload)
	}
}

func TestRelayConflict(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := newRelay(ctx, 500*time.Millisecond)
	defer r.Close()

	key := "test-tid-conflict/sess/0/0"

	var wg sync.WaitGroup
	wg.Add(1)

	// Receiver 1 parks
	go func() {
		defer wg.Done()
		req1 := httptest.NewRequest("GET", "/chunk", nil)
		rec1 := httptest.NewRecorder()
		r.get(rec1, req1, key)
	}()

	time.Sleep(30 * time.Millisecond)

	// Receiver 2 tries to wait on same chunk
	req2 := httptest.NewRequest("GET", "/chunk", nil)
	rec2 := httptest.NewRecorder()
	r.get(rec2, req2, key)

	if rec2.Code != http.StatusConflict {
		t.Fatalf("Receiver 2 expected 409 Conflict, got %d", rec2.Code)
	}

	// Unblock receiver 1 with sender
	putReq := httptest.NewRequest("PUT", "/chunk", bytes.NewReader([]byte("x")))
	putReq.ContentLength = 1
	putRec := httptest.NewRecorder()
	r.put(putRec, putReq, key)

	wg.Wait()
}

func TestRelaySessionLifecycle(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := newRelay(ctx, time.Second)
	defer r.Close()

	tid := "tid_12345678"
	if err := r.openSession(tid, "devA", "devB"); err != nil {
		t.Fatalf("openSession failed: %v", err)
	}

	if !r.authorize(tid, "devA", true) {
		t.Fatal("devA should be authorized sender")
	}
	if !r.authorize(tid, "devB", false) {
		t.Fatal("devB should be authorized receiver")
	}
	if r.authorize(tid, "devC", false) {
		t.Fatal("devC should not be authorized")
	}

	// Close session
	r.CloseSession(tid)

	// Session should no longer exist
	if r.authorize(tid, "devA", true) {
		t.Fatal("session should be purged after CloseSession")
	}
}

func TestRelayJanitorShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	r := newRelay(ctx, time.Second)
	// Cancel context to shut down janitor immediately
	cancel()
	time.Sleep(20 * time.Millisecond)
	r.Close()
	// No goroutine leak or panic
}

func TestRelayPutInvalidContentLength(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := newRelay(ctx, time.Second)
	defer r.Close()

	// Zero content length
	reqZero := httptest.NewRequest("PUT", "/chunk", nil)
	reqZero.ContentLength = 0
	recZero := httptest.NewRecorder()
	r.put(recZero, reqZero, "test/zero/len")
	if recZero.Code != http.StatusLengthRequired {
		t.Fatalf("expected status 411 Length Required for zero content length, got %d", recZero.Code)
	}

	// Negative content length (e.g. chunked without length)
	reqNeg := httptest.NewRequest("PUT", "/chunk", nil)
	reqNeg.ContentLength = -1
	recNeg := httptest.NewRecorder()
	r.put(recNeg, reqNeg, "test/neg/len")
	if recNeg.Code != http.StatusLengthRequired {
		t.Fatalf("expected status 411 Length Required for negative content length, got %d", recNeg.Code)
	}
}
