package client

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// Config is the persisted identity of one device (hubctl / reference client).
type Config struct {
	Server     string `json:"server"`
	DeviceID   string `json:"device_id"`
	Token      string `json:"token"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	PrivateKey string `json:"private_key"` // base64 X25519
	RecvDir    string `json:"recv_dir"`
	StateDir   string `json:"state_dir"`
	// AutoAccept: receive from own devices without asking (P0: always true).
	AutoAccept bool `json:"auto_accept"`

	path string
}

func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	if c.Server == "" || c.Token == "" || c.PrivateKey == "" {
		return nil, errors.New("config incomplete; run `hubctl register` first")
	}
	c.path = path
	return &c, nil
}

func (c *Config) Save(path string) error {
	if path == "" {
		path = c.path
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	c.path = path
	return os.WriteFile(path, b, 0o600)
}

func (c *Config) outboxDir() string  { return filepath.Join(c.StateDir, "outbox") }
func (c *Config) partialDir() string { return filepath.Join(c.RecvDir, ".synchub-partial") }
