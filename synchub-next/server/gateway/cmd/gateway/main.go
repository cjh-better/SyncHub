// Command gateway runs the SyncHub gateway (device registry, presence,
// signaling, streaming relay, ICE config) or, with -mode relay, a stateless
// relay node that only forwards ticket-authorized chunks.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"synchub/gateway/internal/server"
	"synchub/gateway/internal/store"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// ensureSelfSigned creates (once) a long-lived ECDSA certificate in dir and
// returns the cert/key paths and the hex SHA-256 pin of the certificate.
func ensureSelfSigned(dir string, ips []string) (string, string, string, error) {
	certPath, keyPath := filepath.Join(dir, "relay.crt"), filepath.Join(dir, "relay.key")
	if _, err := os.Stat(certPath); err != nil {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", "", "", err
		}
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return "", "", "", err
		}
		serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 62))
		tmpl := &x509.Certificate{
			SerialNumber: serial,
			Subject:      pkix.Name{CommonName: "synchub-relay"},
			NotBefore:    time.Now().Add(-time.Hour),
			NotAfter:     time.Now().AddDate(20, 0, 0),
			KeyUsage:     x509.KeyUsageDigitalSignature,
			ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			DNSNames:     []string{"synchub-relay"},
		}
		for _, ip := range ips {
			if p := net.ParseIP(ip); p != nil {
				tmpl.IPAddresses = append(tmpl.IPAddresses, p)
			}
		}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
		if err != nil {
			return "", "", "", err
		}
		kb, _ := x509.MarshalECPrivateKey(key)
		if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600); err != nil {
			return "", "", "", err
		}
		if err := os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
			return "", "", "", err
		}
	}
	b, err := os.ReadFile(certPath)
	if err != nil {
		return "", "", "", err
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return "", "", "", fmt.Errorf("bad pem in %s", certPath)
	}
	sum := sha256.Sum256(blk.Bytes)
	return certPath, keyPath, hex.EncodeToString(sum[:]), nil
}

func main() {
	mode := flag.String("mode", env("GATEWAY_MODE", "gateway"), "gateway | relay")
	addr := flag.String("addr", env("GATEWAY_ADDR", "127.0.0.1:5040"), "listen address")
	data := flag.String("data", env("GATEWAY_DATA", "./data/devices.json"), "device store file (gateway mode)")
	tlsDir := flag.String("tls-self-signed", env("GATEWAY_TLS_DIR", ""), "serve HTTPS with a self-signed cert kept in this dir")
	tlsIPs := flag.String("tls-ips", env("GATEWAY_TLS_IPS", ""), "comma-separated IP SANs for the self-signed cert")
	printPin := flag.Bool("print-pin", false, "create/print the self-signed cert pin and exit")
	flag.Parse()

	cfg := server.Config{
		AccountUser:       os.Getenv("SYNCHUB_USER"),
		AccountPass:       os.Getenv("SYNCHUB_PASSWORD"),
		AccountPassSHA256: os.Getenv("SYNCHUB_PASSWORD_SHA256"),
		STUNURLs:          splitList(os.Getenv("GATEWAY_STUN_URLS")),
		TURNURLs:          splitList(os.Getenv("GATEWAY_TURN_URLS")),
		TURNSecret:        os.Getenv("GATEWAY_TURN_SECRET"),
		TrustProxy:        env("GATEWAY_TRUST_PROXY", "0") == "1",
	}
	if s := os.Getenv("GATEWAY_RELAY_SECRET"); s != "" {
		b, err := hex.DecodeString(s)
		if err != nil || len(b) < 16 {
			log.Fatalf("GATEWAY_RELAY_SECRET must be >= 16 bytes hex")
		}
		cfg.RelaySecret = b
	} else if *mode == "relay" && !*printPin {
		log.Fatalf("relay mode requires GATEWAY_RELAY_SECRET (shared with the gateway)")
	}
	if s := os.Getenv("GATEWAY_RELAYS"); s != "" {
		if err := json.Unmarshal([]byte(s), &cfg.Relays); err != nil {
			log.Fatalf("GATEWAY_RELAYS: %v", err)
		}
	}

	var certPath, keyPath, pin string
	if *tlsDir != "" {
		var err error
		certPath, keyPath, pin, err = ensureSelfSigned(*tlsDir, splitList(*tlsIPs))
		if err != nil {
			log.Fatalf("tls: %v", err)
		}
		if *printPin {
			fmt.Println(pin)
			return
		}
	}

	var handler http.Handler
	switch *mode {
	case "gateway":
		if cfg.AccountUser == "" || (cfg.AccountPass == "" && cfg.AccountPassSHA256 == "") {
			log.Printf("WARNING: SYNCHUB_USER / SYNCHUB_PASSWORD not set - new devices can only join with a pairing code")
		}
		if len(cfg.RelaySecret) == 0 && len(cfg.Relays) > 0 {
			log.Fatalf("GATEWAY_RELAYS set but GATEWAY_RELAY_SECRET missing")
		}
		st, err := store.Open(*data)
		if err != nil {
			log.Fatalf("open store: %v", err)
		}
		handler = server.New(cfg, st).Handler()
		for _, r := range cfg.Relays {
			log.Printf("relay advertised: %s %s", r.ID, r.URL)
		}
	case "relay":
		handler = server.NewRelayNode(cfg).Handler()
	default:
		log.Fatalf("unknown -mode %q", *mode)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           handler,
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		// No Read/WriteTimeout: relay streams and websockets are long-lived.
	}
	if certPath != "" {
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		log.Printf("TLS self-signed, pin sha256=%s", pin)
	}
	go func() {
		log.Printf("SyncHub %s listening on %s", *mode, *addr)
		var err error
		if certPath != "" {
			err = srv.ListenAndServeTLS(certPath, keyPath)
		} else {
			err = srv.ListenAndServe()
		}
		if err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
