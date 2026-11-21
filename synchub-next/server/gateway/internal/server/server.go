// Package server implements the SyncHub gateway HTTP API: device registry,
// presence/signaling websocket, streaming relay and ICE configuration.
package server

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"synchub/gateway/internal/proto"
	"synchub/gateway/internal/store"
)

type Config struct {
	Context           context.Context
	AccountUser       string // SYNCHUB_USER
	AccountPass       string // SYNCHUB_PASSWORD (plaintext) ...
	AccountPassSHA256 string // ... or SYNCHUB_PASSWORD_SHA256 (hex)
	STUNURLs          []string
	TURNURLs          []string
	TURNSecret        string // coturn use-auth-secret / static-auth-secret
	TrustProxy        bool   // honour X-Real-IP / X-Forwarded-For
	RelayWait         time.Duration
	// RelaySecret signs relay tickets; must be shared with relay nodes.
	RelaySecret []byte
	// Relays advertised to clients. Empty => only the gateway itself, at the
	// base URL the client used.
	Relays []proto.RelayInfo
}

type Server struct {
	cfg    Config
	store  *store.Store
	hub    *Hub
	relay  *Relay
	cancel context.CancelFunc
	mux    *http.ServeMux

	pairMu sync.Mutex
	pairs  map[string]time.Time

	failMu sync.Mutex
	fails  map[string][]time.Time
}

func normalize(cfg Config) Config {
	if cfg.RelayWait == 0 {
		cfg.RelayWait = 30 * time.Second
	}
	if len(cfg.RelaySecret) == 0 {
		cfg.RelaySecret = make([]byte, 32)
		_, _ = rand.Read(cfg.RelaySecret)
	}
	return cfg
}

// New builds the full gateway (control plane + built-in relay).
func New(cfg Config, st *store.Store) *Server {
	cfg = normalize(cfg)
	ctx := cfg.Context
	var cancel context.CancelFunc
	if ctx == nil {
		ctx, cancel = context.WithCancel(context.Background())
	}
	s := &Server{
		cfg:    cfg,
		store:  st,
		cancel: cancel,
		pairs:  map[string]time.Time{},
		fails:  map[string][]time.Time{},
	}
	s.hub = newHub(st)
	s.relay = newRelay(ctx, cfg.RelayWait)
	s.hub.closeSession = s.relay.closeSession
	s.routes()
	return s
}

// NewRelayNode builds a stateless relay-only server (no device store). It
// serves /healthz and ticket-authorized chunk relay only.
func NewRelayNode(cfg Config) *Server {
	cfg = normalize(cfg)
	ctx := cfg.Context
	var cancel context.CancelFunc
	if ctx == nil {
		ctx, cancel = context.WithCancel(context.Background())
	}
	s := &Server{
		cfg:    cfg,
		cancel: cancel,
		pairs:  map[string]time.Time{},
		fails:  map[string][]time.Time{},
	}
	s.relay = newRelay(ctx, cfg.RelayWait)
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "version": proto.Version, "role": "relay"})
	})
	m.HandleFunc("PUT /api/v1/relay/{tid}/{session}/{file}/{chunk}", s.handleRelayPut)
	m.HandleFunc("GET /api/v1/relay/{tid}/{session}/{file}/{chunk}", s.handleRelayGet)
	m.HandleFunc("DELETE /api/v1/relay/{tid}", s.handleRelayClose)
	s.mux = m
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

func (s *Server) Close() {
	if s.cancel != nil {
		s.cancel()
	}
	if s.relay != nil {
		s.relay.Close()
	}
}

func (s *Server) CloseRelaySession(tid string) {
	if s.relay != nil {
		s.relay.closeSession(tid)
	}
}

func (s *Server) handleRelayClose(w http.ResponseWriter, r *http.Request) {
	tid := r.PathValue("tid")
	if !validTransferID(tid) {
		writeErr(w, 400, "invalid transfer_id")
		return
	}
	ip := s.clientIP(r)
	if s.blocked(ip) {
		writeErr(w, http.StatusTooManyRequests, "too many failed attempts")
		return
	}
	c, err := verifyTicket(s.cfg.RelaySecret, ticketFromRequest(r.Header.Get("Authorization")))
	if err != nil {
		s.recordFail(ip)
		writeErr(w, 401, "relay ticket: "+err.Error())
		return
	}
	if c.TID != tid {
		writeErr(w, 403, "ticket not valid for this transfer")
		return
	}
	s.relay.closeSession(tid)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routes() {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "version": proto.Version})
	})
	m.HandleFunc("POST /api/v1/devices/register", s.handleRegister)
	m.HandleFunc("GET /api/v1/devices", s.auth(s.handleDevices))
	m.HandleFunc("PATCH /api/v1/devices/me", s.auth(s.handleRename))
	m.HandleFunc("DELETE /api/v1/devices/{id}", s.auth(s.handleDelete))
	m.HandleFunc("POST /api/v1/pairing-codes", s.auth(s.handlePairingCode))
	m.HandleFunc("GET /api/v1/auth/introspect", s.auth(s.handleIntrospect))
	m.HandleFunc("GET /api/v1/ice", s.auth(s.handleICE))
	m.HandleFunc("GET /api/v1/ws", s.auth(s.hub.serveWS))
	m.HandleFunc("POST /api/v1/relay/sessions", s.auth(s.handleRelaySession))
	m.HandleFunc("POST /api/v1/relay/tickets", s.auth(s.handleRelayTicket))
	m.HandleFunc("PUT /api/v1/relay/{tid}/{session}/{file}/{chunk}", s.handleRelayPut)
	m.HandleFunc("GET /api/v1/relay/{tid}/{session}/{file}/{chunk}", s.handleRelayGet)
	m.HandleFunc("DELETE /api/v1/relay/{tid}", s.handleRelayClose)
	s.mux = m
}

// ---------------------------------------------------------------- helpers

type ctxDevice struct{}

type authedHandler func(w http.ResponseWriter, r *http.Request, dev *store.Device)

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"ok": false, "error": msg})
}

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxy {
		if v := r.Header.Get("X-Real-IP"); v != "" {
			return strings.TrimSpace(v)
		}
		if v := r.Header.Get("X-Forwarded-For"); v != "" {
			return strings.TrimSpace(strings.Split(v, ",")[0])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// Brute-force protection: max 10 failed credential attempts / 10 min / IP.
const (
	failWindow = 10 * time.Minute
	failMax    = 10
)

func (s *Server) blocked(ip string) bool {
	s.failMu.Lock()
	defer s.failMu.Unlock()
	cut := time.Now().Add(-failWindow)
	l := s.fails[ip][:0]
	for _, t := range s.fails[ip] {
		if t.After(cut) {
			l = append(l, t)
		}
	}
	if len(l) == 0 {
		delete(s.fails, ip)
		return false
	}
	s.fails[ip] = l
	return len(l) >= failMax
}

func (s *Server) recordFail(ip string) {
	s.failMu.Lock()
	defer s.failMu.Unlock()
	s.fails[ip] = append(s.fails[ip], time.Now())
	if len(s.fails) > 10000 { // bound memory by pruning expired entries
		cut := time.Now().Add(-failWindow)
		for k, times := range s.fails {
			var active []time.Time
			for _, t := range times {
				if t.After(cut) {
					active = append(active, t)
				}
			}
			if len(active) == 0 {
				delete(s.fails, k)
			} else {
				s.fails[k] = active
			}
		}
	}
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	// Browsers cannot set headers on WebSocket upgrades.
	if r.URL.Path == "/api/v1/ws" {
		return r.URL.Query().Get("token")
	}
	return ""
}

func (s *Server) auth(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := s.clientIP(r)
		if s.blocked(ip) {
			writeErr(w, http.StatusTooManyRequests, "too many failed attempts")
			return
		}
		tok := bearer(r)
		dev, ok := s.store.ByToken(tok)
		if tok == "" || !ok {
			s.recordFail(ip)
			writeErr(w, http.StatusUnauthorized, "invalid device token")
			return
		}
		h(w, r, dev)
	}
}

func (s *Server) checkAccount(r *http.Request) bool {
	u, p, ok := r.BasicAuth()
	if !ok || s.cfg.AccountUser == "" {
		return false
	}
	userOK := subtle.ConstantTimeCompare([]byte(u), []byte(s.cfg.AccountUser)) == 1
	var passOK bool
	switch {
	case s.cfg.AccountPassSHA256 != "":
		h := sha256.Sum256([]byte(p))
		passOK = subtle.ConstantTimeCompare([]byte(hex.EncodeToString(h[:])), []byte(strings.ToLower(s.cfg.AccountPassSHA256))) == 1
	case s.cfg.AccountPass != "":
		passOK = subtle.ConstantTimeCompare([]byte(p), []byte(s.cfg.AccountPass)) == 1
	}
	return userOK && passOK
}

func (s *Server) consumePairingCode(code string) bool {
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	now := time.Now()
	for c, exp := range s.pairs {
		if now.After(exp) {
			delete(s.pairs, c)
		}
	}
	exp, ok := s.pairs[code]
	if !ok || now.After(exp) {
		return false
	}
	delete(s.pairs, code)
	return true
}

func cleanName(n string, max int) string {
	n = strings.TrimSpace(n)
	if !utf8.ValidString(n) {
		return ""
	}
	n = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, n)
	if utf8.RuneCountInString(n) > max {
		n = string([]rune(n)[:max])
	}
	return n
}

func validTransferID(t string) bool {
	if len(t) < 8 || len(t) > 64 {
		return false
	}
	for _, c := range t {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func (s *Server) deviceInfo(d store.Device) proto.DeviceInfo {
	return proto.DeviceInfo{
		ID: d.ID, Name: d.Name, Platform: d.Platform, PublicKey: d.PublicKey,
		Online: s.hub.online(d.ID), LastSeen: d.LastSeen, CreatedAt: d.CreatedAt, LAN: s.hub.lanOf(d.ID),
	}
}

// --------------------------------------------------------------- handlers

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	ip := s.clientIP(r)
	if s.blocked(ip) {
		writeErr(w, http.StatusTooManyRequests, "too many failed attempts")
		return
	}
	code := strings.TrimSpace(r.Header.Get("X-Pairing-Code"))
	authorized := false
	if code != "" {
		authorized = s.consumePairingCode(code)
	} else {
		authorized = s.checkAccount(r)
	}
	if !authorized {
		s.recordFail(ip)
		writeErr(w, http.StatusUnauthorized, "invalid account credentials or pairing code")
		return
	}
	var req proto.RegisterRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeErr(w, 400, "bad json")
		return
	}
	req.Name = cleanName(req.Name, 64)
	req.Platform = cleanName(req.Platform, 32)
	pk, err := base64.StdEncoding.DecodeString(req.PublicKey)
	if req.Name == "" || err != nil || len(pk) != 32 {
		writeErr(w, 400, "name and 32-byte base64 public_key required")
		return
	}
	d, tok, err := s.store.Register(req.Name, req.Platform, req.PublicKey)
	if err != nil {
		log.Printf("register: %v", err)
		writeErr(w, 500, "store error")
		return
	}
	log.Printf("registered device %s (%s, %s) from %s", d.ID, d.Name, d.Platform, ip)
	s.hub.broadcastDevices()
	writeJSON(w, 200, proto.RegisterResponse{DeviceID: d.ID, Token: tok})
}

func (s *Server) handleDevices(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	list := s.store.List()
	out := make([]proto.DeviceInfo, 0, len(list))
	for _, d := range list {
		out = append(out, s.deviceInfo(d))
	}
	writeJSON(w, 200, map[string]any{"self": dev.ID, "devices": out})
}

func (s *Server) handleRename(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeErr(w, 400, "bad json")
		return
	}
	name := cleanName(req.Name, 64)
	if name == "" {
		writeErr(w, 400, "name required")
		return
	}
	if err := s.store.Rename(dev.ID, name); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.hub.broadcastDevices()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	id := r.PathValue("id")
	if err := s.store.Delete(id); err != nil {
		writeErr(w, 404, err.Error())
		return
	}
	log.Printf("device %s revoked by %s", id, dev.ID)
	s.hub.kick(id)
	s.hub.broadcastDevices()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *Server) handlePairingCode(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		writeErr(w, 500, "rng")
		return
	}
	code := fmt.Sprintf("%06d", n.Int64())
	exp := time.Now().Add(5 * time.Minute)
	s.pairMu.Lock()
	s.pairs[code] = exp
	s.pairMu.Unlock()
	writeJSON(w, 200, proto.PairingCode{Code: code, ExpiresAt: exp.UTC()})
}

func (s *Server) handleIntrospect(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	writeJSON(w, 200, map[string]any{"ok": true, "device_id": dev.ID, "name": dev.Name, "platform": dev.Platform})
}

func (s *Server) handleICE(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	servers := []proto.ICEServer{}
	if len(s.cfg.STUNURLs) > 0 {
		servers = append(servers, proto.ICEServer{URLs: s.cfg.STUNURLs})
	}
	if len(s.cfg.TURNURLs) > 0 && s.cfg.TURNSecret != "" {
		// coturn REST API credentials: username = "<unix-expiry>:<device-id>",
		// credential = base64(HMAC-SHA1(secret, username)).
		user := strconv.FormatInt(time.Now().Add(12*time.Hour).Unix(), 10) + ":" + dev.ID
		mac := hmac.New(sha1.New, []byte(s.cfg.TURNSecret))
		mac.Write([]byte(user))
		servers = append(servers, proto.ICEServer{
			URLs: s.cfg.TURNURLs, Username: user,
			Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil)),
		})
	}
	writeJSON(w, 200, map[string]any{"ice_servers": servers})
}

func (s *Server) relayList() []proto.RelayInfo {
	if len(s.cfg.Relays) == 0 {
		return []proto.RelayInfo{{ID: "main", URL: ""}} // "" = the gateway base URL
	}
	return s.cfg.Relays
}

func (s *Server) handleRelaySession(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req proto.RelaySessionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeErr(w, 400, "bad json")
		return
	}
	if !validTransferID(req.TransferID) {
		writeErr(w, 400, "invalid transfer_id")
		return
	}
	if _, ok := s.store.Get(req.Receiver); !ok || req.Receiver == dev.ID {
		writeErr(w, 400, "unknown receiver")
		return
	}
	if err := s.relay.openSession(req.TransferID, dev.ID, req.Receiver); err != nil {
		writeErr(w, 409, err.Error())
		return
	}
	writeJSON(w, 200, proto.RelayGrant{
		Relays: s.relayList(),
		Ticket: signTicket(s.cfg.RelaySecret, ticketClaims{TID: req.TransferID, Device: dev.ID, Role: "s", Exp: time.Now().Add(ticketTTL).Unix()}),
	})
}

func (s *Server) handleRelayTicket(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req proto.RelayTicketRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeErr(w, 400, "bad json")
		return
	}
	if !s.relay.authorize(req.TransferID, dev.ID, false) {
		writeErr(w, 403, "not the receiver of this transfer")
		return
	}
	writeJSON(w, 200, proto.RelayGrant{
		Relays: s.relayList(),
		Ticket: signTicket(s.cfg.RelaySecret, ticketClaims{TID: req.TransferID, Device: dev.ID, Role: "r", Exp: time.Now().Add(ticketTTL).Unix()}),
	})
}

// relayKey scopes the rendezvous by session so a stale PUT from an aborted
// session (old key) can never be delivered to a newer session's GET.
func relayKey(r *http.Request) (tid string, key string, ok bool) {
	tid = r.PathValue("tid")
	sess := r.PathValue("session")
	f, err1 := strconv.ParseUint(r.PathValue("file"), 10, 31)
	c, err2 := strconv.ParseUint(r.PathValue("chunk"), 10, 40)
	if !validTransferID(tid) || len(sess) < 4 || !validTransferID(sess+"________") || err1 != nil || err2 != nil {
		return "", "", false
	}
	return tid, fmt.Sprintf("%s/%s/%d/%d", tid, sess, f, c), true
}

// relayAuth checks "Authorization: Ticket <t>" for the transfer and role.
func (s *Server) relayAuth(w http.ResponseWriter, r *http.Request, tid, role string) bool {
	ip := s.clientIP(r)
	if s.blocked(ip) {
		writeErr(w, http.StatusTooManyRequests, "too many failed attempts")
		return false
	}
	c, err := verifyTicket(s.cfg.RelaySecret, ticketFromRequest(r.Header.Get("Authorization")))
	if err != nil {
		s.recordFail(ip)
		writeErr(w, 401, "relay ticket: "+err.Error())
		return false
	}
	if c.TID != tid || c.Role != role {
		writeErr(w, 403, "ticket not valid for this transfer/role")
		return false
	}
	return true
}

func (s *Server) handleRelayPut(w http.ResponseWriter, r *http.Request) {
	tid, key, ok := relayKey(r)
	if !ok {
		writeErr(w, 400, "bad relay path")
		return
	}
	if !s.relayAuth(w, r, tid, "s") {
		return
	}
	if r.ContentLength <= 0 || r.ContentLength > proto.MaxChunkSize+proto.AEADOverhead {
		writeErr(w, 411, "Content-Length required (<= 16 MiB + 16)")
		return
	}
	s.relay.put(w, r, key)
}

func (s *Server) handleRelayGet(w http.ResponseWriter, r *http.Request) {
	tid, key, ok := relayKey(r)
	if !ok {
		writeErr(w, 400, "bad relay path")
		return
	}
	if !s.relayAuth(w, r, tid, "r") {
		return
	}
	s.relay.get(w, r, key)
}
