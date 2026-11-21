package server

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"synchub/gateway/internal/proto"
	"synchub/gateway/internal/store"
)

const (
	wsReadLimit   = 8 << 20 // manifests of large folders can be big
	wsSendBuffer  = 256
	wsPingEvery   = 25 * time.Second
	wsWriteTimout = 15 * time.Second
)

type wsClient struct {
	dev    string
	conn   *websocket.Conn
	send   chan []byte
	cancel context.CancelFunc
	lan    []string // guarded by Hub.mu
}

// Hub tracks connected devices and forwards signaling frames between them.
type Hub struct {
	st           *store.Store
	mu           sync.RWMutex
	conns        map[string]map[*wsClient]struct{}
	closeSession func(tid string)
}

func newHub(st *store.Store) *Hub {
	return &Hub{st: st, conns: map[string]map[*wsClient]struct{}{}}
}

func (h *Hub) online(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.conns[id]) > 0
}

func (h *Hub) add(c *wsClient) (first bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m := h.conns[c.dev]
	if m == nil {
		m = map[*wsClient]struct{}{}
		h.conns[c.dev] = m
	}
	m[c] = struct{}{}
	return len(m) == 1
}

func (h *Hub) remove(c *wsClient) (last bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m := h.conns[c.dev]
	delete(m, c)
	if len(m) == 0 {
		delete(h.conns, c.dev)
		return true
	}
	return false
}

func (h *Hub) clientsOf(id string) []*wsClient {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]*wsClient, 0, len(h.conns[id]))
	for c := range h.conns[id] {
		out = append(out, c)
	}
	return out
}

func (h *Hub) all() []*wsClient {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var out []*wsClient
	for _, m := range h.conns {
		for c := range m {
			out = append(out, c)
		}
	}
	return out
}

// enqueue never blocks; a client that cannot keep up is disconnected.
func (c *wsClient) enqueue(b []byte) bool {
	select {
	case c.send <- b:
		return true
	default:
		c.cancel()
		return false
	}
}

func mustEnvelope(typ string, payload any) []byte {
	var raw json.RawMessage
	if payload != nil {
		raw, _ = json.Marshal(payload)
	}
	b, _ := json.Marshal(proto.Envelope{Type: typ, Payload: raw})
	return b
}

func (h *Hub) lanOf(id string) []string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var out []string
	seen := map[string]bool{}
	for c := range h.conns[id] {
		for _, u := range c.lan {
			if !seen[u] {
				seen[u] = true
				out = append(out, u)
			}
		}
	}
	return out
}

func (h *Hub) devicesFrame() []byte {
	list := h.st.List()
	out := make([]proto.DeviceInfo, 0, len(list))
	for _, d := range list {
		out = append(out, proto.DeviceInfo{
			ID: d.ID, Name: d.Name, Platform: d.Platform, PublicKey: d.PublicKey,
			Online: h.online(d.ID), LastSeen: d.LastSeen, CreatedAt: d.CreatedAt, LAN: h.lanOf(d.ID),
		})
	}
	return mustEnvelope("devices", out)
}

func (h *Hub) broadcastDevices() {
	b := h.devicesFrame()
	for _, c := range h.all() {
		c.enqueue(b)
	}
}

func (h *Hub) broadcastPresence(id string, online bool) {
	b := mustEnvelope("presence", proto.Presence{DeviceID: id, Online: online})
	for _, c := range h.all() {
		if c.dev != id {
			c.enqueue(b)
		}
	}
}

// kick disconnects every connection of a revoked device.
func (h *Hub) kick(id string) {
	for _, c := range h.clientsOf(id) {
		c.cancel()
	}
}

func (h *Hub) serveWS(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Native apps send no Origin; browsers (web client) are same-origin
		// behind nginx. Token auth already happened above.
		InsecureSkipVerify: true,
	})
	if err != nil {
		return
	}
	conn.SetReadLimit(wsReadLimit)
	ctx, cancel := context.WithCancel(context.Background())
	c := &wsClient{dev: dev.ID, conn: conn, send: make(chan []byte, wsSendBuffer), cancel: cancel}
	first := h.add(c)
	h.st.Touch(dev.ID, false)
	log.Printf("ws connect %s (%s)", dev.ID, dev.Name)
	if first {
		h.broadcastPresence(dev.ID, true)
	}
	c.enqueue(h.devicesFrame())

	var wg sync.WaitGroup
	defer func() {
		cancel()
		wg.Wait()
		conn.Close(websocket.StatusNormalClosure, "")
		if h.remove(c) {
			h.st.Touch(dev.ID, true)
			h.broadcastPresence(dev.ID, false)
		}
		log.Printf("ws disconnect %s", dev.ID)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		h.writeLoop(ctx, c)
	}()
	h.readLoop(ctx, c)
}

func (h *Hub) writeLoop(ctx context.Context, c *wsClient) {
	t := time.NewTicker(wsPingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case b := <-c.send:
			wctx, cancel := context.WithTimeout(ctx, wsWriteTimout)
			err := c.conn.Write(wctx, websocket.MessageText, b)
			cancel()
			if err != nil {
				c.cancel()
				return
			}
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, wsWriteTimout)
			err := c.conn.Ping(pctx)
			cancel()
			if err != nil {
				c.cancel()
				return
			}
		}
	}
}

func (h *Hub) readLoop(ctx context.Context, c *wsClient) {
	for {
		typ, data, err := c.conn.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var env proto.Envelope
		if json.Unmarshal(data, &env) != nil {
			c.enqueue(errFrame(env.ID, "bad_request", "invalid json"))
			continue
		}
		switch env.Type {
		case "ping":
			b, _ := json.Marshal(proto.Envelope{Type: "pong", ID: env.ID})
			c.enqueue(b)
		case "signal":
			h.forward(c, env)
		case "hello":
			var hello proto.Hello
			if json.Unmarshal(env.Payload, &hello) == nil {
				var lan []string
				for _, u := range hello.LAN {
					if len(lan) < 8 && len(u) < 64 && (strings.HasPrefix(u, "http://") || strings.HasPrefix(u, "https://")) {
						lan = append(lan, u)
					}
				}
				h.mu.Lock()
				c.lan = lan
				h.mu.Unlock()
				h.broadcastDevices()
			}
		default:
			c.enqueue(errFrame(env.ID, "bad_request", "unknown type"))
		}
	}
}

func errFrame(id, code, msg string) []byte {
	p, _ := json.Marshal(proto.ErrorPayload{Code: code, Message: msg})
	b, _ := json.Marshal(proto.Envelope{Type: "error", ID: id, Payload: p})
	return b
}

func (h *Hub) forward(from *wsClient, env proto.Envelope) {
	if _, ok := h.st.Get(env.To); !ok {
		from.enqueue(errFrame(env.ID, "unknown_device", env.To))
		return
	}
	if env.Type == "signal" && h.closeSession != nil {
		var sig proto.Signal
		if json.Unmarshal(env.Payload, &sig) == nil {
			if sig.Kind == proto.KindDone && sig.Done != nil && sig.Done.TransferID != "" {
				h.closeSession(sig.Done.TransferID)
			} else if sig.Kind == proto.KindCancel && sig.Cancel != nil && sig.Cancel.TransferID != "" {
				h.closeSession(sig.Cancel.TransferID)
			}
		}
	}
	targets := h.clientsOf(env.To)
	if len(targets) == 0 {
		from.enqueue(errFrame(env.ID, "offline", env.To))
		return
	}
	env.From = from.dev // never trust a client-supplied sender
	b, _ := json.Marshal(env)
	for _, t := range targets {
		t.enqueue(b)
	}
}
