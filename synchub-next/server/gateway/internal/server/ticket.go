package server

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Relay tickets let stateless relay nodes authorize chunk traffic without
// access to the device store:
//
//	ticket = b64url(json{t: transfer_id, d: device, r: "s"|"r", e: unix_exp}) "." b64url(HMAC-SHA256(secret, payload))
type ticketClaims struct {
	TID    string `json:"t"`
	Device string `json:"d"`
	Role   string `json:"r"` // "s" sender, "r" receiver
	Exp    int64  `json:"e"`
}

const ticketTTL = 24 * time.Hour

func signTicket(secret []byte, c ticketClaims) string {
	p, _ := json.Marshal(c)
	ps := base64.RawURLEncoding.EncodeToString(p)
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(ps))
	return ps + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func verifyTicket(secret []byte, tok string) (*ticketClaims, error) {
	ps, sig, ok := strings.Cut(tok, ".")
	if !ok || len(tok) > 1024 {
		return nil, errors.New("malformed ticket")
	}
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(ps))
	want := base64.RawURLEncoding.EncodeToString(m.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(sig), []byte(want)) != 1 {
		return nil, errors.New("bad ticket signature")
	}
	raw, err := base64.RawURLEncoding.DecodeString(ps)
	if err != nil {
		return nil, err
	}
	var c ticketClaims
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, err
	}
	if time.Now().Unix() > c.Exp {
		return nil, errors.New("ticket expired")
	}
	if c.Role != "s" && c.Role != "r" {
		return nil, errors.New("bad role")
	}
	return &c, nil
}

func ticketFromRequest(h string) string {
	if len(h) > 7 && strings.EqualFold(h[:7], "ticket ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}
