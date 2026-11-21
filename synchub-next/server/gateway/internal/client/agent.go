package client

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"synchub/gateway/internal/e2e"
	"synchub/gateway/internal/proto"
)

// Progress is reported periodically for every active transfer.
type Progress struct {
	TransferID string
	Direction  string // "send" | "recv"
	Peer       string
	Title      string
	Route      string
	Done       int64
	Total      int64
	BytesPerS  float64
}

// Result is reported once a transfer finishes (successfully or permanently failed).
type Result struct {
	TransferID string
	Direction  string
	OK         bool
	Err        string
	Saved      []string
}

type Options struct {
	Receive      bool     // handle incoming offers
	LANListen    string   // e.g. ":53318"; "" disables the direct LAN receiver
	LANAdvertise []string // override advertised LAN URLs (tests / manual setups)
	OnlyTransfer string   // send mode: only drive this outbox entry and return when it ends
	Workers      int      // parallel chunk streams (default 4)
	LimitBPS     int64    // optional send rate limit, bytes/s
	OnProgress   func(Progress)
	OnResult     func(Result)
	Logf         func(format string, args ...any)
}

type transferProgress struct {
	p        Progress
	done     atomic.Int64
	lastDone int64
	lastAt   time.Time
}

type inSession struct {
	from   string
	cancel context.CancelFunc
	done   chan struct{}
}

type Agent struct {
	cfg  *Config
	api  *API
	priv *ecdh.PrivateKey
	opt  Options

	mu        sync.Mutex
	self      string
	devices   map[string]proto.DeviceInfo
	conn      *websocket.Conn
	waiters   map[string]chan proto.Signal
	activeOut map[string]context.CancelFunc // tid -> cancel
	outPeer   map[string]string             // tid -> receiver
	nextTry   map[string]time.Time
	backoff   map[string]time.Duration
	incoming  map[string]*inSession
	progress  map[string]*transferProgress
	badRelay  map[string]time.Time // "tid|relay" -> avoid until
	sinks     map[string]*sink     // "tid|session" -> active incoming session
	lan       *lanServer           // nil when LAN receiving is disabled

	writeMu  sync.Mutex
	wake     chan struct{}
	finished chan Result
	limiter  *rateLimiter
}

func NewAgent(cfg *Config, opt Options) (*Agent, error) {
	priv, err := e2e.ParsePrivate(cfg.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("private key: %w", err)
	}
	if opt.Workers <= 0 {
		opt.Workers = 4
	}
	if opt.Logf == nil {
		opt.Logf = log.Printf
	}
	a := &Agent{
		cfg: cfg, api: NewAPI(cfg.Server, cfg.Token), priv: priv, opt: opt,
		self: cfg.DeviceID, devices: map[string]proto.DeviceInfo{},
		waiters: map[string]chan proto.Signal{}, activeOut: map[string]context.CancelFunc{},
		outPeer: map[string]string{}, nextTry: map[string]time.Time{}, backoff: map[string]time.Duration{},
		incoming: map[string]*inSession{}, progress: map[string]*transferProgress{},
		wake: make(chan struct{}, 1), finished: make(chan Result, 8),
	}
	if opt.LimitBPS > 0 {
		a.limiter = &rateLimiter{bps: opt.LimitBPS}
	}
	return a, nil
}

func (a *Agent) API() *API { return a.api }

func (a *Agent) logf(format string, args ...any) { a.opt.Logf(format, args...) }

func (a *Agent) poke() {
	select {
	case a.wake <- struct{}{}:
	default:
	}
}

// Run connects and processes events until ctx ends, or (in send mode) until
// the selected transfer finishes.
func (a *Agent) Run(ctx context.Context) (*Result, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	if a.opt.Receive && a.opt.LANListen != "" {
		if err := a.startLAN(a.opt.LANListen); err != nil {
			a.logf("LAN receiver disabled: %v", err)
		} else {
			defer a.lan.srv.Close()
		}
	}
	go a.connLoop(ctx)
	go a.scheduler(ctx)
	go a.progressLoop(ctx)
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case r := <-a.finished:
			if a.opt.OnResult != nil {
				a.opt.OnResult(r)
			}
			if a.opt.OnlyTransfer != "" && r.TransferID == a.opt.OnlyTransfer {
				return &r, nil
			}
		}
	}
}

func (a *Agent) finish(r Result) {
	a.mu.Lock()
	delete(a.progress, r.TransferID)
	a.mu.Unlock()
	a.finished <- r
}

// ------------------------------------------------------------ websocket

func (a *Agent) connLoop(ctx context.Context) {
	back := time.Second
	for ctx.Err() == nil {
		err := a.connectOnce(ctx)
		if ctx.Err() != nil {
			return
		}
		if IsStatus(err, 401) {
			a.logf("gateway rejected token (device revoked?): %v", err)
		} else if err != nil {
			a.logf("gateway connection lost: %v (retry in %s)", err, back)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(back):
		}
		if back < 30*time.Second {
			back *= 2
		}
	}
}

func (a *Agent) connectOnce(ctx context.Context) error {
	dctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	conn, resp, err := websocket.Dial(dctx, a.api.wsURL(), &websocket.DialOptions{
		HTTPClient: a.api.HTTP,
		HTTPHeader: http.Header{"Authorization": {"Bearer " + a.api.Token}},
	})
	cancel()
	if err != nil {
		if resp != nil && resp.StatusCode >= 300 {
			return &HTTPError{Status: resp.StatusCode, Body: err.Error()}
		}
		return err
	}
	conn.SetReadLimit(8 << 20)
	a.mu.Lock()
	a.conn = conn
	a.mu.Unlock()
	a.logf("connected to gateway as %s (%s)", a.cfg.Name, a.self)
	a.sendHello(ctx)
	defer func() {
		a.mu.Lock()
		a.conn = nil
		a.mu.Unlock()
		conn.CloseNow()
	}()
	// keepalive
	kctx, kcancel := context.WithCancel(ctx)
	defer kcancel()
	go func() {
		t := time.NewTicker(25 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-kctx.Done():
				return
			case <-t.C:
				pctx, c := context.WithTimeout(kctx, 15*time.Second)
				err := conn.Ping(pctx)
				c()
				if err != nil {
					conn.CloseNow()
					return
				}
			}
		}
	}()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return err
		}
		var env proto.Envelope
		if json.Unmarshal(data, &env) != nil {
			continue
		}
		a.dispatch(ctx, env)
	}
}

func (a *Agent) dispatch(ctx context.Context, env proto.Envelope) {
	switch env.Type {
	case "devices":
		var list []proto.DeviceInfo
		if json.Unmarshal(env.Payload, &list) == nil {
			a.mu.Lock()
			a.devices = map[string]proto.DeviceInfo{}
			for _, d := range list {
				a.devices[d.ID] = d
			}
			a.mu.Unlock()
			a.poke()
		}
	case "presence":
		var p proto.Presence
		if json.Unmarshal(env.Payload, &p) != nil {
			return
		}
		a.mu.Lock()
		if d, ok := a.devices[p.DeviceID]; ok {
			d.Online = p.Online
			a.devices[p.DeviceID] = d
		}
		var cancels []context.CancelFunc
		if p.Online {
			for tid, peer := range a.outPeer {
				if peer == p.DeviceID {
					delete(a.nextTry, tid)
					delete(a.backoff, tid)
				}
			}
		} else {
			for tid, peer := range a.outPeer {
				if c := a.activeOut[tid]; c != nil && peer == p.DeviceID {
					cancels = append(cancels, c)
				}
			}
			for _, s := range a.incoming {
				if s.from == p.DeviceID {
					cancels = append(cancels, s.cancel)
				}
			}
		}
		a.mu.Unlock()
		for _, c := range cancels {
			c()
		}
		a.poke()
	case "error":
		var e proto.ErrorPayload
		_ = json.Unmarshal(env.Payload, &e)
		if e.Code != "offline" {
			a.logf("gateway error: %s %s", e.Code, e.Message)
		}
	case "signal":
		var sig proto.Signal
		if json.Unmarshal(env.Payload, &sig) != nil {
			return
		}
		a.onSignal(ctx, env.From, sig)
	}
}

func (a *Agent) onSignal(ctx context.Context, from string, sig proto.Signal) {
	switch sig.Kind {
	case proto.KindOffer:
		if a.opt.Receive && sig.Offer != nil {
			go a.handleOffer(ctx, from, sig.Offer)
		}
	case proto.KindAnswer:
		if sig.Answer != nil {
			a.deliver("answer:"+sig.Answer.TransferID+":"+sig.Answer.Session, sig)
		}
	case proto.KindDone:
		if sig.Done != nil {
			a.deliver("done:"+sig.Done.TransferID+":"+sig.Done.Session, sig)
		}
	case proto.KindCancel:
		if sig.Cancel != nil {
			a.onCancel(from, sig.Cancel)
		}
	}
}

func (a *Agent) deliver(key string, sig proto.Signal) {
	a.mu.Lock()
	ch := a.waiters[key]
	a.mu.Unlock()
	if ch != nil {
		select {
		case ch <- sig:
		default:
		}
	}
}

func (a *Agent) waitFor(key string) (chan proto.Signal, func()) {
	ch := make(chan proto.Signal, 1)
	a.mu.Lock()
	a.waiters[key] = ch
	a.mu.Unlock()
	return ch, func() {
		a.mu.Lock()
		if a.waiters[key] == ch {
			delete(a.waiters, key)
		}
		a.mu.Unlock()
	}
}

var errNotConnected = errors.New("not connected to gateway")

func (a *Agent) sendSignal(ctx context.Context, to string, sig proto.Signal) error {
	a.mu.Lock()
	conn := a.conn
	a.mu.Unlock()
	if conn == nil {
		return errNotConnected
	}
	p, err := json.Marshal(sig)
	if err != nil {
		return err
	}
	b, _ := json.Marshal(proto.Envelope{Type: "signal", To: to, ID: randToken(6), Payload: p})
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	wctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	return conn.Write(wctx, websocket.MessageText, b)
}

func (a *Agent) device(ctx context.Context, id string) (proto.DeviceInfo, bool) {
	a.mu.Lock()
	d, ok := a.devices[id]
	a.mu.Unlock()
	if ok {
		return d, true
	}
	resp, err := a.api.Devices(ctx)
	if err != nil {
		return proto.DeviceInfo{}, false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, x := range resp.Devices {
		a.devices[x.ID] = x
	}
	d, ok = a.devices[id]
	return d, ok
}

// Devices returns the current device snapshot (excluding self unless asked).
func (a *Agent) Devices() []proto.DeviceInfo {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]proto.DeviceInfo, 0, len(a.devices))
	for _, d := range a.devices {
		out = append(out, d)
	}
	return out
}

// ------------------------------------------------------------ progress

func (a *Agent) trackProgress(p Progress) *transferProgress {
	tp := &transferProgress{p: p, lastAt: time.Now()}
	tp.done.Store(p.Done)
	tp.lastDone = p.Done
	a.mu.Lock()
	a.progress[p.TransferID] = tp
	a.mu.Unlock()
	return tp
}

func (a *Agent) progressLoop(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if a.opt.OnProgress == nil {
				continue
			}
			a.mu.Lock()
			var snaps []Progress
			for _, tp := range a.progress {
				d := tp.done.Load()
				dt := now.Sub(tp.lastAt).Seconds()
				p := tp.p
				p.Done = d
				if dt > 0 {
					p.BytesPerS = float64(d-tp.lastDone) / dt
				}
				tp.lastDone, tp.lastAt = d, now
				snaps = append(snaps, p)
			}
			a.mu.Unlock()
			for _, p := range snaps {
				a.opt.OnProgress(p)
			}
		}
	}
}

// ------------------------------------------------------------ utilities

func randToken(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// NewTransferID returns a fresh transfer id.
func NewTransferID() string { return "t" + strings.ReplaceAll(randToken(15), "-", "x") }

type rateLimiter struct {
	mu   sync.Mutex
	bps  int64
	next time.Time
}

func (r *rateLimiter) wait(ctx context.Context, n int) error {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	now := time.Now()
	if r.next.Before(now) {
		r.next = now
	}
	at := r.next
	r.next = r.next.Add(time.Duration(float64(n) / float64(r.bps) * float64(time.Second)))
	r.mu.Unlock()
	if d := time.Until(at); d > 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(d):
		}
	}
	return nil
}

func writeJSONFile(path string, v any) error {
	b, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
