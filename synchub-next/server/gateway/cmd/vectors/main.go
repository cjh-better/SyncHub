// Command vectors prints deterministic E2E test vectors (protocol/test-vectors.json)
// so other implementations (Dart/Flutter) can verify byte-for-byte compatibility.
package main

import (
	"crypto/ecdh"
	"encoding/hex"
	"encoding/json"
	"os"

	"synchub/gateway/internal/e2e"
)

func key(h string) *ecdh.PrivateKey {
	b, _ := hex.DecodeString(h)
	k, err := ecdh.X25519().NewPrivateKey(b)
	if err != nil {
		panic(err)
	}
	return k
}

func main() {
	senderPriv := "a8abababababababababababababababababababababababababababababab6b"
	receiverPriv := "c8cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd4d"
	ephPriv := "e8efefefefefefefefefefefefefefefefefefefefefefefefefefefefefef6f"
	s, r, eph := key(senderPriv), key(receiverPriv), key(ephPriv)
	tid, session := "tVectorTransfer01", "sessAbc123"
	ephPub := e2e.EncodePublic(eph.PublicKey())
	aead, err := e2e.ReceiverSession(r, ephPub, s.PublicKey(), tid, session)
	if err != nil {
		panic(err)
	}
	type chunk struct {
		File       int    `json:"file"`
		Chunk      int64  `json:"chunk"`
		Plaintext  string `json:"plaintext_hex"`
		Ciphertext string `json:"ciphertext_hex"`
	}
	var chunks []chunk
	for _, c := range []struct {
		f int
		c int64
		p string
	}{{0, 0, "hello synchub"}, {3, 1234567, "跨端传输 ✓"}, {1, 0, ""}} {
		ct := e2e.Seal(aead, tid, session, c.f, c.c, []byte(c.p))
		chunks = append(chunks, chunk{c.f, c.c, hex.EncodeToString([]byte(c.p)), hex.EncodeToString(ct)})
	}
	out := map[string]any{
		"description":           "SyncHub E2E v1 vectors. Keys are raw X25519 scalars (hex); public keys are base64 as on the wire.",
		"sender_private_hex":    senderPriv,
		"sender_public_b64":     e2e.EncodePublic(s.PublicKey()),
		"receiver_private_hex":  receiverPriv,
		"receiver_public_b64":   e2e.EncodePublic(r.PublicKey()),
		"ephemeral_private_hex": ephPriv,
		"ephemeral_public_b64":  ephPub,
		"transfer_id":           tid,
		"session":               session,
		"receiver_fingerprint":  e2e.Fingerprint(e2e.EncodePublic(r.PublicKey())),
		"chunks":                chunks,
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
}
