package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"

	"synchub/gateway/internal/proto"
)

// Direct LAN route (protocol §7 "lan"):
//
//	GET /synchub/v1/ping                              -> {"device_id": "..."}
//	PUT /synchub/v1/chunk/{tid}/{session}/{file}/{chunk}  body = sealed chunk -> 204
//
// No extra authentication: every chunk is AEAD-sealed with the session key,
// so anything not produced by the real sender is rejected (400) without
// disturbing the session.
const DefaultLANPort = 53318

type lanServer struct {
	a    *Agent
	ln   net.Listener
	srv  *http.Server
	port int
}

func (a *Agent) startLAN(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	ls := &lanServer{a: a, ln: ln, port: ln.Addr().(*net.TCPAddr).Port}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /synchub/v1/ping", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"device_id": a.self, "version": proto.Version})
	})
	mux.HandleFunc("PUT /synchub/v1/chunk/{tid}/{session}/{file}/{chunk}", ls.handleChunk)
	ls.srv = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second}
	go func() { _ = ls.srv.Serve(ln) }()
	a.lan = ls
	a.logf("LAN receiver on :%d (%s)", ls.port, strings.Join(ls.urls(), ", "))
	return nil
}

func (ls *lanServer) handleChunk(w http.ResponseWriter, r *http.Request) {
	f, err1 := strconv.Atoi(r.PathValue("file"))
	c, err2 := strconv.ParseInt(r.PathValue("chunk"), 10, 64)
	if err1 != nil || err2 != nil || r.ContentLength <= 0 || r.ContentLength > proto.MaxChunkSize+proto.AEADOverhead {
		http.Error(w, "bad request", 400)
		return
	}
	s := ls.a.lookupSink(r.PathValue("tid"), r.PathValue("session"))
	if s == nil {
		http.Error(w, "no such session", 404)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, r.ContentLength))
	if err != nil || int64(len(body)) != r.ContentLength {
		http.Error(w, "short body", 400)
		return
	}
	switch err := s.accept(chunkRef{f, c}, body); {
	case err == nil:
		w.WriteHeader(204)
	case errors.Is(err, errUnexpected):
		http.Error(w, err.Error(), 409)
	case errors.Is(err, errBadChunk):
		http.Error(w, err.Error(), 400)
	default:
		http.Error(w, err.Error(), 500)
	}
}

// urls lists http://<private-ipv4>:port for every up, non-loopback interface.
func (ls *lanServer) urls() []string {
	if len(ls.a.opt.LANAdvertise) > 0 {
		return ls.a.opt.LANAdvertise
	}
	var out []string
	ifs, _ := net.Interfaces()
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, ad := range addrs {
			ipn, ok := ad.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipn.IP.To4()
			if ip == nil || !ip.IsPrivate() {
				continue
			}
			out = append(out, fmt.Sprintf("http://%s:%d", ip, ls.port))
			if len(out) == 8 {
				return out
			}
		}
	}
	return out
}

func (a *Agent) sendHello(ctx context.Context) {
	if a.lan == nil {
		return
	}
	a.mu.Lock()
	conn := a.conn
	a.mu.Unlock()
	if conn == nil {
		return
	}
	p, _ := json.Marshal(proto.Hello{LAN: a.lan.urls()})
	b, _ := json.Marshal(proto.Envelope{Type: "hello", Payload: p})
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_ = conn.Write(wctx, websocket.MessageText, b)
}

// ---------------------------------------------------------------- sender

// chunkPusher abstracts the relay and LAN upload paths.
type chunkPusher interface {
	PutChunk(ctx context.Context, tid, session string, file int, chunk int64, data []byte) error
	Name() string
}

func (r *RelayConn) Name() string { return "relay:" + r.ID }

type lanConn struct {
	base string
	http *http.Client
}

func (l *lanConn) Name() string { return "lan" }

var lanHTTP = &http.Client{Transport: &http.Transport{
	Proxy:               nil, // never send LAN traffic through a proxy
	MaxIdleConnsPerHost: 16,
	IdleConnTimeout:     60 * time.Second,
	DialContext:         (&net.Dialer{Timeout: 2 * time.Second}).DialContext,
}}

func (l *lanConn) PutChunk(ctx context.Context, tid, session string, file int, chunk int64, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	u := fmt.Sprintf("%s/synchub/v1/chunk/%s/%s/%d/%d", l.base, tid, session, file, chunk)
	req, err := http.NewRequestWithContext(ctx, "PUT", u, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.ContentLength = int64(len(data))
	resp, err := l.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 204 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return &HTTPError{Status: resp.StatusCode, Body: strings.TrimSpace(string(b))}
	}
	return nil
}

// probeLAN returns the first LAN endpoint of the target device that answers
// with the expected device id, or nil.
func probeLAN(ctx context.Context, dev proto.DeviceInfo) *lanConn {
	if len(dev.LAN) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	found := make(chan string, len(dev.LAN))
	for _, u := range dev.LAN {
		go func(u string) {
			req, _ := http.NewRequestWithContext(ctx, "GET", u+"/synchub/v1/ping", nil)
			resp, err := lanHTTP.Do(req)
			if err != nil {
				found <- ""
				return
			}
			defer resp.Body.Close()
			var p struct {
				DeviceID string `json:"device_id"`
			}
			if json.NewDecoder(io.LimitReader(resp.Body, 1024)).Decode(&p) == nil && p.DeviceID == dev.ID {
				found <- u
				return
			}
			found <- ""
		}(u)
	}
	for range dev.LAN {
		select {
		case u := <-found:
			if u != "" {
				return &lanConn{base: u, http: lanHTTP}
			}
		case <-ctx.Done():
			return nil
		}
	}
	return nil
}
