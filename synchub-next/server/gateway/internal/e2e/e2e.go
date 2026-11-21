// Package e2e implements the end-to-end chunk encryption used by transfers.
//
// Key agreement (per offer/session):
//
//	ikm  = X25519(eph_s, R) || X25519(S, R)      (sender view)
//	     = X25519(r, EPH)   || X25519(r, S_pub)  (receiver view)
//	key  = HKDF-SHA256(ikm, salt = transfer_id "|" session, info = "synchub-e2e-v1", 32)
//
// The second DH term authenticates the sender's registered static key.
// Each chunk is sealed with AES-256-GCM, nonce = BE32(file) || BE64(chunk),
// AAD = "synchub/v1|" transfer_id "|" session "|" file "|" chunk.
package e2e

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"strconv"
)

const info = "synchub-e2e-v1"

func GenerateKey() (*ecdh.PrivateKey, error) { return ecdh.X25519().GenerateKey(rand.Reader) }

func ParsePrivate(b64 string) (*ecdh.PrivateKey, error) {
	b, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, err
	}
	return ecdh.X25519().NewPrivateKey(b)
}

func ParsePublic(b64 string) (*ecdh.PublicKey, error) {
	b, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, err
	}
	return ecdh.X25519().NewPublicKey(b)
}

func EncodePrivate(k *ecdh.PrivateKey) string { return base64.StdEncoding.EncodeToString(k.Bytes()) }
func EncodePublic(k *ecdh.PublicKey) string   { return base64.StdEncoding.EncodeToString(k.Bytes()) }

// Fingerprint returns a short human-comparable fingerprint of a public key.
func Fingerprint(pubB64 string) string {
	b, _ := base64.StdEncoding.DecodeString(pubB64)
	h := sha256.Sum256(b)
	s := base64.RawStdEncoding.EncodeToString(h[:9])
	return s[:4] + "-" + s[4:8] + "-" + s[8:12]
}

func derive(ikm []byte, transferID, session string) (cipher.AEAD, error) {
	key, err := hkdf.Key(sha256.New, ikm, []byte(transferID+"|"+session), info, 32)
	if err != nil {
		return nil, err
	}
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(blk)
}

// SenderSession creates an ephemeral key and the session AEAD.
func SenderSession(static *ecdh.PrivateKey, receiverPub *ecdh.PublicKey, transferID, session string) (ephPub string, aead cipher.AEAD, err error) {
	eph, err := GenerateKey()
	if err != nil {
		return "", nil, err
	}
	a, err := eph.ECDH(receiverPub)
	if err != nil {
		return "", nil, err
	}
	b, err := static.ECDH(receiverPub)
	if err != nil {
		return "", nil, err
	}
	aead, err = derive(append(a, b...), transferID, session)
	return EncodePublic(eph.PublicKey()), aead, err
}

// ReceiverSession derives the same AEAD on the receiving side.
func ReceiverSession(static *ecdh.PrivateKey, ephPubB64 string, senderPub *ecdh.PublicKey, transferID, session string) (cipher.AEAD, error) {
	eph, err := ParsePublic(ephPubB64)
	if err != nil {
		return nil, err
	}
	a, err := static.ECDH(eph)
	if err != nil {
		return nil, err
	}
	b, err := static.ECDH(senderPub)
	if err != nil {
		return nil, err
	}
	return derive(append(a, b...), transferID, session)
}

func nonceAAD(transferID, session string, file int, chunk int64) ([]byte, []byte) {
	n := make([]byte, 12)
	binary.BigEndian.PutUint32(n[:4], uint32(file))
	binary.BigEndian.PutUint64(n[4:], uint64(chunk))
	aad := []byte("synchub/v1|" + transferID + "|" + session + "|" + strconv.Itoa(file) + "|" + strconv.FormatInt(chunk, 10))
	return n, aad
}

func Seal(aead cipher.AEAD, transferID, session string, file int, chunk int64, plain []byte) []byte {
	n, aad := nonceAAD(transferID, session, file, chunk)
	return aead.Seal(nil, n, plain, aad)
}

var ErrAuth = errors.New("chunk authentication failed")

func Open(aead cipher.AEAD, transferID, session string, file int, chunk int64, sealed []byte) ([]byte, error) {
	n, aad := nonceAAD(transferID, session, file, chunk)
	p, err := aead.Open(sealed[:0], n, sealed, aad)
	if err != nil {
		return nil, ErrAuth
	}
	return p, nil
}
