package client

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"synchub/gateway/internal/e2e"
	"synchub/gateway/internal/proto"
	"synchub/gateway/internal/server"
	"synchub/gateway/internal/store"
)

type logBuf struct {
	mu sync.Mutex
	b  strings.Builder
}

func (l *logBuf) logf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	fmt.Fprintf(&l.b, format+"\n", args...)
}

func (l *logBuf) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func startGateway(t *testing.T) *httptest.Server {
	return startGatewayCfg(t, server.Config{})
}

func startGatewayCfg(t *testing.T, cfg server.Config) *httptest.Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "devices.json"))
	if err != nil {
		t.Fatal(err)
	}
	cfg.AccountUser, cfg.AccountPass, cfg.RelayWait = "u", "p", 3*time.Second
	srv := server.New(cfg, st)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() {
		ts.Close()
		time.Sleep(80 * time.Millisecond)
	})
	return ts
}

// transferOnce sends paths from a fresh sender to a fresh receiver and
// returns the receiver config plus the sender log.
func transferOnce(t *testing.T, base string, paths func(dir string) []string) (*Config, string) {
	t.Helper()
	snd := newDevice(t, base, "Sender")
	rcv := newDevice(t, base, "Receiver")
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	var rlog, slog logBuf
	ra, _ := NewAgent(rcv, Options{Receive: true, Logf: rlog.logf})
	rdone := make(chan struct{})
	go func() {
		_, _ = ra.Run(ctx)
		close(rdone)
	}()
	defer func() {
		cancel()
		<-rdone
	}()
	sa, _ := NewAgent(snd, Options{Logf: slog.logf})
	e, err := sa.Enqueue(paths(t.TempDir()), rcv.DeviceID, nil)
	if err != nil {
		t.Fatal(err)
	}
	s2, _ := NewAgent(snd, Options{OnlyTransfer: e.TransferID, Logf: slog.logf})
	res, err := s2.Run(ctx)
	if err != nil || !res.OK {
		t.Fatalf("transfer failed: %+v %v\nsender:\n%s\nreceiver:\n%s", res, err, slog.String(), rlog.String())
	}
	return rcv, slog.String()
}

func TestDirectLANTransfer(t *testing.T) {
	ts := startGateway(t)
	snd := newDevice(t, ts.URL, "Sender")
	rcv := newDevice(t, ts.URL, "Receiver")
	payload := make([]byte, 10<<20)
	_, _ = rand.Read(payload)
	src := filepath.Join(t.TempDir(), "lan.bin")
	_ = os.WriteFile(src, payload, 0o644)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	var rlog, slog logBuf
	ra, _ := NewAgent(rcv, Options{Receive: true, Logf: rlog.logf, LANListen: "127.0.0.1:53399", LANAdvertise: []string{"http://127.0.0.1:53399"}})
	rdone := make(chan struct{})
	go func() {
		_, _ = ra.Run(ctx)
		close(rdone)
	}()
	defer func() {
		cancel()
		<-rdone
	}()
	time.Sleep(300 * time.Millisecond) // let the hello reach the gateway
	sa, _ := NewAgent(snd, Options{Logf: slog.logf})
	e, err := sa.Enqueue([]string{src}, rcv.DeviceID, nil)
	if err != nil {
		t.Fatal(err)
	}
	s2, _ := NewAgent(snd, Options{OnlyTransfer: e.TransferID, Logf: slog.logf})
	res, err := s2.Run(ctx)
	if err != nil || !res.OK {
		t.Fatalf("lan transfer failed: %+v %v\nsender:\n%s\nreceiver:\n%s", res, err, slog.String(), rlog.String())
	}
	if !strings.Contains(slog.String(), "via lan") {
		t.Fatalf("expected LAN route:\n%s", slog.String())
	}
	if got, _ := os.ReadFile(filepath.Join(rcv.RecvDir, "lan.bin")); !bytes.Equal(got, payload) {
		t.Fatal("content mismatch over LAN")
	}
}

func TestExternalPinnedRelayAndFallback(t *testing.T) {
	secret := []byte("fixture-relay-secret-32bytes!!")
	node := httptest.NewTLSServer(server.NewRelayNode(server.Config{RelaySecret: secret, RelayWait: 3 * time.Second}).Handler())
	t.Cleanup(node.Close)
	sum := sha256.Sum256(node.Certificate().Raw)
	pin := hex.EncodeToString(sum[:])

	payload := make([]byte, 6<<20)
	_, _ = rand.Read(payload)
	mk := func(dir string) []string {
		p := filepath.Join(dir, "clip.mp4")
		_ = os.WriteFile(p, payload, 0o644)
		return []string{p}
	}

	// 1) only the external TLS node is advertised -> must be used (and pinned)
	gw := startGatewayCfg(t, server.Config{RelaySecret: secret, Relays: []proto.RelayInfo{{ID: "la", URL: node.URL, CertSHA256: pin}}})
	rcv, log1 := transferOnce(t, gw.URL, mk)
	if !strings.Contains(log1, "via relay:la") {
		t.Fatalf("expected relay la:\n%s", log1)
	}
	if got, _ := os.ReadFile(filepath.Join(rcv.RecvDir, "clip.mp4")); !bytes.Equal(got, payload) {
		t.Fatal("content mismatch via external relay")
	}

	// 2) a wrong pin must be rejected; the gateway's own relay is the fallback
	gw2 := startGatewayCfg(t, server.Config{RelaySecret: secret, Relays: []proto.RelayInfo{
		{ID: "evil", URL: node.URL, CertSHA256: strings.Repeat("00", 32)},
		{ID: "main", URL: ""},
	}})
	_, log2 := transferOnce(t, gw2.URL, mk)
	if !strings.Contains(log2, "relay evil unreachable") || !strings.Contains(log2, "via relay:main") {
		t.Fatalf("expected pin rejection + fallback to main:\n%s", log2)
	}
}

func newDevice(t *testing.T, base, name string) *Config {
	t.Helper()
	priv, _ := e2e.GenerateKey()
	resp, err := Register(context.Background(), base, "u", "p", "", proto.RegisterRequest{Name: name, Platform: "test", PublicKey: e2e.EncodePublic(priv.PublicKey())})
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	return &Config{Server: base, DeviceID: resp.DeviceID, Token: resp.Token, Name: name, Platform: "test",
		PrivateKey: e2e.EncodePrivate(priv), RecvDir: filepath.Join(dir, "recv"), StateDir: filepath.Join(dir, "state"), AutoAccept: true}
}

func writeRandom(t *testing.T, path string, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	_, _ = rand.Read(b)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	return b
}

func TestRegisterRejectsBadPassword(t *testing.T) {
	ts := startGateway(t)
	priv, _ := e2e.GenerateKey()
	_, err := Register(context.Background(), ts.URL, "u", "wrong", "", proto.RegisterRequest{Name: "x", PublicKey: e2e.EncodePublic(priv.PublicKey())})
	if !IsStatus(err, 401) {
		t.Fatalf("want 401, got %v", err)
	}
}

func TestPairingCode(t *testing.T) {
	ts := startGateway(t)
	a := newDevice(t, ts.URL, "A")
	pc, err := NewAPI(ts.URL, a.Token).PairingCode(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	priv, _ := e2e.GenerateKey()
	req := proto.RegisterRequest{Name: "B", PublicKey: e2e.EncodePublic(priv.PublicKey())}
	if _, err := Register(context.Background(), ts.URL, "", "", pc.Code, req); err != nil {
		t.Fatalf("pair: %v", err)
	}
	if _, err := Register(context.Background(), ts.URL, "", "", pc.Code, req); !IsStatus(err, 401) {
		t.Fatalf("pairing code must be single-use, got %v", err)
	}
}

func TestFolderTransferViaRelay(t *testing.T) {
	ts := startGateway(t)
	snd := newDevice(t, ts.URL, "Sender")
	rcv := newDevice(t, ts.URL, "Receiver")

	src := filepath.Join(t.TempDir(), "项目 资料")
	big := writeRandom(t, filepath.Join(src, "video.bin"), 9*1024*1024+123) // 3 chunks
	small := writeRandom(t, filepath.Join(src, "sub", "deep", "notes.txt"), 777)
	if err := os.WriteFile(filepath.Join(src, "empty.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(src, "empty-dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	single := make([]byte, 5000)
	_, _ = rand.Read(single)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	var rlog logBuf
	ra, _ := NewAgent(rcv, Options{Receive: true, Logf: rlog.logf})
	rdone := make(chan struct{})
	go func() {
		_, _ = ra.Run(ctx)
		close(rdone)
	}()
	defer func() {
		cancel()
		<-rdone
	}()

	var slog logBuf
	sa, _ := NewAgent(snd, Options{Logf: slog.logf})
	photo := filepath.Join(t.TempDir(), "photo.jpg")
	_ = os.WriteFile(photo, single, 0o644)
	e, err := sa.Enqueue([]string{src, photo}, rcv.DeviceID, nil)
	if err != nil {
		t.Fatal(err)
	}
	sa2, _ := NewAgent(snd, Options{OnlyTransfer: e.TransferID, Logf: slog.logf})
	res, err := sa2.Run(ctx)
	if err != nil {
		t.Fatalf("send: %v\nsender log:\n%s\nreceiver log:\n%s", err, slog.String(), rlog.String())
	}
	if !res.OK {
		t.Fatalf("send failed: %s", res.Err)
	}
	check := func(rel string, want []byte) {
		got, err := os.ReadFile(filepath.Join(rcv.RecvDir, rel))
		if err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%s: content mismatch", rel)
		}
	}
	check(filepath.Join("项目 资料", "video.bin"), big)
	check(filepath.Join("项目 资料", "sub", "deep", "notes.txt"), small)
	check(filepath.Join("项目 资料", "empty.txt"), nil)
	check("photo.jpg", single)
	if st, err := os.Stat(filepath.Join(rcv.RecvDir, "项目 资料", "empty-dir")); err != nil || !st.IsDir() {
		t.Fatalf("empty dir not recreated: %v", err)
	}
	if _, err := os.Stat(filepath.Join(rcv.RecvDir, ".synchub-partial", e.TransferID)); !os.IsNotExist(err) {
		t.Fatalf("partial state not cleaned up")
	}
	if ents, _ := os.ReadDir(filepath.Join(snd.StateDir, "outbox")); len(ents) != 0 {
		t.Fatalf("outbox not cleaned: %v", ents)
	}
}

func TestResumeAfterReceiverRestart(t *testing.T) {
	ts := startGateway(t)
	snd := newDevice(t, ts.URL, "Sender")
	rcv := newDevice(t, ts.URL, "Receiver")
	src := filepath.Join(t.TempDir(), "big.bin")
	data := writeRandom(t, src, 48*1024*1024) // 12 chunks

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	var rlog, slog logBuf

	// first receiver instance: killed mid-transfer
	r1ctx, r1cancel := context.WithCancel(ctx)
	ra1, _ := NewAgent(rcv, Options{Receive: true, Logf: rlog.logf, Workers: 2})
	r1done := make(chan struct{})
	go func() {
		_, _ = ra1.Run(r1ctx)
		close(r1done)
	}()

	sa, _ := NewAgent(snd, Options{Logf: slog.logf})
	e, err := sa.Enqueue([]string{src}, rcv.DeviceID, nil)
	if err != nil {
		t.Fatal(err)
	}
	sender, _ := NewAgent(snd, Options{OnlyTransfer: e.TransferID, Logf: slog.logf, Workers: 2, LimitBPS: 16 << 20})
	type out struct {
		r   *Result
		err error
	}
	resCh := make(chan out, 1)
	go func() { r, err := sender.Run(ctx); resCh <- out{r, err} }()

	// wait until some chunks landed, then kill the receiver
	statePath := filepath.Join(rcv.RecvDir, ".synchub-partial", e.TransferID, "f0.part")
	deadline := time.Now().Add(20 * time.Second)
	for {
		if st, err := os.Stat(statePath); err == nil && st.Size() >= 12<<20 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no progress before kill\nsender:\n%s\nreceiver:\n%s", slog.String(), rlog.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
	r1cancel()
	<-r1done
	time.Sleep(500 * time.Millisecond)

	// second receiver instance resumes
	ra2, _ := NewAgent(rcv, Options{Receive: true, Logf: rlog.logf})
	r2done := make(chan struct{})
	go func() {
		_, _ = ra2.Run(ctx)
		close(r2done)
	}()
	defer func() {
		cancel()
		<-r2done
	}()

	o := <-resCh
	if o.err != nil || o.r == nil || !o.r.OK {
		t.Fatalf("resume failed: %+v %v\nsender:\n%s\nreceiver:\n%s", o.r, o.err, slog.String(), rlog.String())
	}
	got, err := os.ReadFile(filepath.Join(rcv.RecvDir, "big.bin"))
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("content mismatch after resume: %v", err)
	}
	if !strings.Contains(slog.String(), "resuming at") || strings.Count(slog.String(), "resuming at 0.0%") > 1 {
		t.Fatalf("expected a resumed session (non-zero offset)\nsender:\n%s", slog.String())
	}
	t.Logf("sender log:\n%s", slog.String())
}

func TestSanitizeRelPath(t *testing.T) {
	bad := []string{"", "/etc/passwd", "../x", "a/../../b", "a//b", `a\b`, "C:/x", "a/./b"}
	for _, p := range bad {
		if _, err := SanitizeRelPath(p); err == nil {
			t.Errorf("%q should be rejected", p)
		}
	}
	got, err := SanitizeRelPath("dir/CON.txt/a:b?.txt ")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, "/") != "dir/_CON.txt/a_b_.txt" {
		t.Errorf("got %v", got)
	}
}

func TestE2ERoundTrip(t *testing.T) {
	s, _ := e2e.GenerateKey()
	r, _ := e2e.GenerateKey()
	eph, sa, err := e2e.SenderSession(s, r.PublicKey(), "tid12345", "sess")
	if err != nil {
		t.Fatal(err)
	}
	ra, err := e2e.ReceiverSession(r, eph, s.PublicKey(), "tid12345", "sess")
	if err != nil {
		t.Fatal(err)
	}
	ct := e2e.Seal(sa, "tid12345", "sess", 2, 7, []byte("hello"))
	pt, err := e2e.Open(ra, "tid12345", "sess", 2, 7, append([]byte(nil), ct...))
	if err != nil || string(pt) != "hello" {
		t.Fatalf("roundtrip: %v %q", err, pt)
	}
	if _, err := e2e.Open(ra, "tid12345", "sess", 2, 8, append([]byte(nil), ct...)); err == nil {
		t.Fatal("chunk index must be authenticated")
	}
	// a different (impostor) sender static key must not derive the same key
	m, _ := e2e.GenerateKey()
	ra2, _ := e2e.ReceiverSession(r, eph, m.PublicKey(), "tid12345", "sess")
	if _, err := e2e.Open(ra2, "tid12345", "sess", 2, 7, append([]byte(nil), ct...)); err == nil {
		t.Fatal("sender authentication failed")
	}
}
