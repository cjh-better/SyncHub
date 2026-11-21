package server

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// Relay pairs a sender PUT and a receiver GET for the same chunk key and
// streams the body straight through. Nothing is written to disk and at most
// one io.Copy buffer per chunk is held in memory.
type Relay struct {
	wait   time.Duration
	ctx    context.Context
	cancel context.CancelFunc

	mu       sync.Mutex
	meets    map[string]*meet
	sessions map[string]*relaySession
}

type relaySession struct {
	sender, receiver string
	lastActive       atomic.Int64 // unix seconds
}

type meet struct {
	mu     sync.Mutex
	refs   int
	waiter *waiter
	ready  chan struct{}
}

const (
	stWaiting int32 = iota
	stClaimed
	stCancelled
)

type waiter struct {
	w     http.ResponseWriter
	state atomic.Int32
	done  chan struct{}
}

const sessionTTL = 48 * time.Hour

func newRelay(ctx context.Context, wait time.Duration) *Relay {
	if ctx == nil {
		ctx = context.Background()
	}
	rctx, cancel := context.WithCancel(ctx)
	r := &Relay{
		wait:     wait,
		ctx:      rctx,
		cancel:   cancel,
		meets:    map[string]*meet{},
		sessions: map[string]*relaySession{},
	}
	go r.janitor()
	return r
}

func (r *Relay) Close() {
	if r.cancel != nil {
		r.cancel()
	}
}

func (r *Relay) janitor() {
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			cut := time.Now().Add(-sessionTTL).Unix()
			r.mu.Lock()
			for k, s := range r.sessions {
				if s.lastActive.Load() < cut {
					delete(r.sessions, k)
				}
			}
			r.mu.Unlock()
		}
	}
}

func (r *Relay) closeSession(tid string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.sessions, tid)
}

// CloseSession closes and purges the relay session for tid.
func (r *Relay) CloseSession(tid string) {
	r.closeSession(tid)
}

func (r *Relay) openSession(tid, sender, receiver string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if s, ok := r.sessions[tid]; ok {
		if s.sender != sender || s.receiver != receiver {
			return errors.New("transfer_id already used by other devices")
		}
		s.lastActive.Store(time.Now().Unix())
		return nil
	}
	s := &relaySession{sender: sender, receiver: receiver}
	s.lastActive.Store(time.Now().Unix())
	r.sessions[tid] = s
	return nil
}

func (r *Relay) authorize(tid, dev string, isSender bool) bool {
	r.mu.Lock()
	s, ok := r.sessions[tid]
	r.mu.Unlock()
	if !ok {
		return false
	}
	s.lastActive.Store(time.Now().Unix())
	if isSender {
		return s.sender == dev
	}
	return s.receiver == dev
}

func (r *Relay) acquire(key string) *meet {
	r.mu.Lock()
	defer r.mu.Unlock()
	m := r.meets[key]
	if m == nil {
		m = &meet{ready: make(chan struct{}, 1)}
		r.meets[key] = m
	}
	m.refs++
	return m
}

func (r *Relay) release(key string, m *meet) {
	r.mu.Lock()
	defer r.mu.Unlock()
	m.refs--
	if m.refs == 0 && r.meets[key] == m {
		delete(r.meets, key)
	}
}

// get is the receiver side: park until a sender arrives, then let the sender
// stream into our ResponseWriter.
func (r *Relay) get(w http.ResponseWriter, req *http.Request, key string) {
	m := r.acquire(key)
	defer r.release(key, m)

	wt := &waiter{w: w, done: make(chan struct{})}

	m.mu.Lock()
	if m.waiter != nil && m.waiter.state.Load() == stWaiting {
		m.mu.Unlock()
		writeErr(w, http.StatusConflict, "another receiver is already waiting for this chunk")
		return
	}
	m.waiter = wt
	select {
	case m.ready <- struct{}{}:
	default:
	}
	m.mu.Unlock()

	timer := time.NewTimer(r.wait)
	defer timer.Stop()

	select {
	case <-wt.done:
		return
	case <-timer.C:
	case <-req.Context().Done():
	}

	m.mu.Lock()
	if wt.state.CompareAndSwap(stWaiting, stCancelled) {
		if m.waiter == wt {
			m.waiter = nil
		}
		m.mu.Unlock()
		if req.Context().Err() == nil {
			writeErr(w, http.StatusGatewayTimeout, "sender not ready")
		}
		return
	}
	m.mu.Unlock()

	<-wt.done // a sender claimed us; wait for the copy to finish
}

// put is the sender side.
func (r *Relay) put(w http.ResponseWriter, req *http.Request, key string) {
	if req.ContentLength <= 0 {
		writeErr(w, http.StatusLengthRequired, "content length required")
		return
	}

	m := r.acquire(key)
	defer r.release(key, m)

	timer := time.NewTimer(r.wait)
	defer timer.Stop()

	for {
		m.mu.Lock()
		wt := m.waiter
		if wt != nil && wt.state.CompareAndSwap(stWaiting, stClaimed) {
			m.waiter = nil
			m.mu.Unlock()

			// Read full chunk into memory first to verify stream health before sending HTTP 200 headers to receiver
			buf := make([]byte, req.ContentLength)
			_, err := io.ReadFull(req.Body, buf)
			if err != nil {
				writeErr(wt.w, http.StatusBadGateway, "stream interrupted")
				close(wt.done)
				writeErr(w, http.StatusBadGateway, "stream interrupted")
				return
			}

			// Stream health verified: now send HTTP 200 OK headers and body to receiver
			h := wt.w.Header()
			h.Set("Content-Type", "application/octet-stream")
			h.Set("Content-Length", strconv.FormatInt(req.ContentLength, 10))
			h.Set("Cache-Control", "no-store")
			wt.w.WriteHeader(http.StatusOK)
			_, _ = wt.w.Write(buf)
			close(wt.done)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if wt != nil && wt.state.Load() == stCancelled {
			m.waiter = nil
		}
		m.mu.Unlock()

		select {
		case <-m.ready:
		case <-timer.C:
			writeErr(w, http.StatusGatewayTimeout, "receiver not ready")
			return
		case <-req.Context().Done():
			return
		}
	}
}
