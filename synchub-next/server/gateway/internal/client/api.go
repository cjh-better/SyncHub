package client

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"synchub/gateway/internal/proto"
)

// API is a thin HTTP client for the gateway.
type API struct {
	Base  string
	Token string
	HTTP  *http.Client
}

func NewAPI(base, token string) *API {
	return &API{
		Base:  strings.TrimRight(base, "/"),
		Token: token,
		HTTP: &http.Client{Transport: &http.Transport{
			Proxy:               http.ProxyFromEnvironment,
			MaxIdleConnsPerHost: 16,
			IdleConnTimeout:     90 * time.Second,
			ForceAttemptHTTP2:   true,
		}},
	}
}

type HTTPError struct {
	Status int
	Body   string
}

func (e *HTTPError) Error() string { return fmt.Sprintf("http %d: %s", e.Status, e.Body) }

func IsStatus(err error, code int) bool {
	var he *HTTPError
	return errors.As(err, &he) && he.Status == code
}

func (a *API) do(ctx context.Context, method, path string, body io.Reader, size int64, hdr http.Header, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, a.Base+path, body)
	if err != nil {
		return err
	}
	if size >= 0 && body != nil {
		req.ContentLength = size
	}
	for k, v := range hdr {
		req.Header[k] = v
	}
	if a.Token != "" && req.Header.Get("Authorization") == "" {
		req.Header.Set("Authorization", "Bearer "+a.Token)
	}
	resp, err := a.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return &HTTPError{Status: resp.StatusCode, Body: strings.TrimSpace(string(b))}
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return nil
}

func (a *API) jsonReq(ctx context.Context, method, path string, in, out any, hdr http.Header) error {
	var body io.Reader
	size := int64(-1)
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body, size = bytes.NewReader(b), int64(len(b))
		if hdr == nil {
			hdr = http.Header{}
		}
		hdr.Set("Content-Type", "application/json")
	}
	return a.do(ctx, method, path, body, size, hdr, out)
}

// Register enrolls a device with account credentials or a pairing code.
func Register(ctx context.Context, base, user, pass, code string, req proto.RegisterRequest) (*proto.RegisterResponse, error) {
	a := NewAPI(base, "")
	hdr := http.Header{}
	if code != "" {
		hdr.Set("X-Pairing-Code", code)
	} else {
		r, _ := http.NewRequest("GET", "/", nil)
		r.SetBasicAuth(user, pass)
		hdr.Set("Authorization", r.Header.Get("Authorization"))
	}
	var out proto.RegisterResponse
	if err := a.jsonReq(ctx, "POST", "/api/v1/devices/register", req, &out, hdr); err != nil {
		return nil, err
	}
	return &out, nil
}

type DevicesResponse struct {
	Self    string             `json:"self"`
	Devices []proto.DeviceInfo `json:"devices"`
}

func (a *API) Devices(ctx context.Context) (*DevicesResponse, error) {
	var out DevicesResponse
	return &out, a.jsonReq(ctx, "GET", "/api/v1/devices", nil, &out, nil)
}

func (a *API) PairingCode(ctx context.Context) (*proto.PairingCode, error) {
	var out proto.PairingCode
	return &out, a.jsonReq(ctx, "POST", "/api/v1/pairing-codes", struct{}{}, &out, nil)
}

func (a *API) DeleteDevice(ctx context.Context, id string) error {
	return a.jsonReq(ctx, "DELETE", "/api/v1/devices/"+id, nil, nil, nil)
}

func (a *API) OpenRelay(ctx context.Context, tid, receiver string) (*proto.RelayGrant, error) {
	var g proto.RelayGrant
	return &g, a.jsonReq(ctx, "POST", "/api/v1/relay/sessions", proto.RelaySessionRequest{TransferID: tid, Receiver: receiver}, &g, nil)
}

func (a *API) RelayTicket(ctx context.Context, tid string) (*proto.RelayGrant, error) {
	var g proto.RelayGrant
	return &g, a.jsonReq(ctx, "POST", "/api/v1/relay/tickets", proto.RelayTicketRequest{TransferID: tid}, &g, nil)
}

// RelayConn talks to one relay node with a transfer ticket.
type RelayConn struct {
	ID     string
	Base   string
	Ticket string
	HTTP   *http.Client
}

var (
	pinnedMu      sync.Mutex
	pinnedClients = map[string]*http.Client{}
)

// pinnedClient returns an HTTP client that accepts exactly one self-signed
// certificate, identified by the hex SHA-256 of its DER encoding.
func pinnedClient(fp string) *http.Client {
	fp = strings.ToLower(strings.ReplaceAll(fp, ":", ""))
	pinnedMu.Lock()
	defer pinnedMu.Unlock()
	if c := pinnedClients[fp]; c != nil {
		return c
	}
	c := &http.Client{Transport: &http.Transport{
		Proxy:               http.ProxyFromEnvironment,
		MaxIdleConnsPerHost: 16,
		IdleConnTimeout:     90 * time.Second,
		ForceAttemptHTTP2:   true,
		TLSClientConfig: &tls.Config{
			MinVersion:         tls.VersionTLS12,
			InsecureSkipVerify: true, // replaced by the pin check below
			VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
				if len(raw) == 0 {
					return errors.New("no certificate")
				}
				sum := sha256.Sum256(raw[0])
				if hex.EncodeToString(sum[:]) != fp {
					return errors.New("relay certificate pin mismatch")
				}
				return nil
			},
		},
	}}
	pinnedClients[fp] = c
	return c
}

// Relay builds a connection to a relay from a grant entry.
func (a *API) Relay(info proto.RelayInfo, ticket string) *RelayConn {
	rc := &RelayConn{ID: info.ID, Base: strings.TrimRight(info.URL, "/"), Ticket: ticket, HTTP: a.HTTP}
	if rc.Base == "" {
		rc.Base = a.Base
	}
	if info.CertSHA256 != "" {
		rc.HTTP = pinnedClient(info.CertSHA256)
	}
	return rc
}

// Ping measures the relay's /healthz round trip.
func (r *RelayConn) Ping(ctx context.Context) (time.Duration, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", r.Base+"/healthz", nil)
	if err != nil {
		return 0, err
	}
	t := time.Now()
	resp, err := r.HTTP.Do(req)
	if err != nil {
		return 0, err
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 {
		return 0, &HTTPError{Status: resp.StatusCode}
	}
	return time.Since(t), nil
}

func relayPath(tid, session string, file int, chunk int64) string {
	return fmt.Sprintf("/api/v1/relay/%s/%s/%d/%d", tid, session, file, chunk)
}

// chunkTimeout bounds one chunk request: the relay's 30 s rendezvous wait
// plus the transfer of a 4 MiB chunk at >= ~48 KiB/s. A stuck connection
// therefore fails and is retried instead of hanging the session.
const chunkTimeout = 2 * time.Minute

func (r *RelayConn) PutChunk(ctx context.Context, tid, session string, file int, chunk int64, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, chunkTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "PUT", r.Base+relayPath(tid, session, file, chunk), bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.ContentLength = int64(len(data))
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "Ticket "+r.Ticket)
	resp, err := r.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return &HTTPError{Status: resp.StatusCode, Body: strings.TrimSpace(string(b))}
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return nil
}

func (r *RelayConn) GetChunk(ctx context.Context, tid, session string, file int, chunk int64, max int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, chunkTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", r.Base+relayPath(tid, session, file, chunk), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Ticket "+r.Ticket)
	resp, err := r.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, &HTTPError{Status: resp.StatusCode, Body: strings.TrimSpace(string(b))}
	}
	if resp.ContentLength > max {
		return nil, fmt.Errorf("chunk too large: %d", resp.ContentLength)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if err != nil {
		return nil, err
	}
	if resp.ContentLength >= 0 && int64(len(b)) != resp.ContentLength {
		return nil, io.ErrUnexpectedEOF
	}
	return b, nil
}

func (a *API) wsURL() string {
	u := a.Base
	switch {
	case strings.HasPrefix(u, "https://"):
		u = "wss://" + u[len("https://"):]
	case strings.HasPrefix(u, "http://"):
		u = "ws://" + u[len("http://"):]
	}
	return u + "/api/v1/ws"
}
