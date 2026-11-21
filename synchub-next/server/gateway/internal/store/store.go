// Package store persists registered devices in a small JSON file.
package store

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

var ErrNotFound = errors.New("device not found")

type Device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Platform  string    `json:"platform"`
	PublicKey string    `json:"public_key"`
	TokenHash string    `json:"token_hash"`
	CreatedAt time.Time `json:"created_at"`
	LastSeen  time.Time `json:"last_seen"`
}

type fileData struct {
	Version int                `json:"version"`
	Devices map[string]*Device `json:"devices"`
}

type Store struct {
	mu      sync.RWMutex
	path    string
	data    fileData
	byToken map[string]string // token hash -> device id
}

func Open(path string) (*Store, error) {
	s := &Store{path: path, data: fileData{Version: 1, Devices: map[string]*Device{}}, byToken: map[string]string{}}
	b, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(b, &s.data); err != nil {
			return nil, err
		}
		if s.data.Devices == nil {
			s.data.Devices = map[string]*Device{}
		}
	}
	for id, d := range s.data.Devices {
		s.byToken[d.TokenHash] = id
	}
	return s, nil
}

func hashToken(tok string) string {
	h := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(h[:])
}

func randID(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// saveLocked writes atomically; caller holds s.mu (write).
func (s *Store) saveLocked() error {
	b, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Register creates a device and returns it with its plaintext token.
func (s *Store) Register(name, platform, pubKey string) (*Device, string, error) {
	tok := "shd_" + randID(32)
	now := time.Now().UTC()
	d := &Device{
		ID:        "dev_" + randID(9),
		Name:      name,
		Platform:  platform,
		PublicKey: pubKey,
		TokenHash: hashToken(tok),
		CreatedAt: now,
		LastSeen:  now,
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.Devices[d.ID] = d
	s.byToken[d.TokenHash] = d.ID
	if err := s.saveLocked(); err != nil {
		delete(s.data.Devices, d.ID)
		delete(s.byToken, d.TokenHash)
		return nil, "", err
	}
	cp := *d
	return &cp, tok, nil
}

// ByToken resolves a bearer token to a device copy.
func (s *Store) ByToken(tok string) (*Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.byToken[hashToken(tok)]
	if !ok {
		return nil, false
	}
	cp := *s.data.Devices[id]
	return &cp, true
}

func (s *Store) Get(id string) (*Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	d, ok := s.data.Devices[id]
	if !ok {
		return nil, false
	}
	cp := *d
	return &cp, true
}

func (s *Store) List() []Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Device, 0, len(s.data.Devices))
	for _, d := range s.data.Devices {
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (s *Store) Delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.data.Devices[id]
	if !ok {
		return ErrNotFound
	}
	delete(s.data.Devices, id)
	delete(s.byToken, d.TokenHash)
	return s.saveLocked()
}

func (s *Store) Rename(id, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.data.Devices[id]
	if !ok {
		return ErrNotFound
	}
	d.Name = name
	return s.saveLocked()
}

// Touch updates LastSeen; persisted only when persist is true.
func (s *Store) Touch(id string, persist bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d, ok := s.data.Devices[id]; ok {
		d.LastSeen = time.Now().UTC()
		if persist {
			_ = s.saveLocked()
		}
	}
}
