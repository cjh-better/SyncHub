// Package proto defines the wire types shared by the gateway and clients.
// See protocol/PROTOCOL.md for the full specification.
package proto

import (
	"encoding/json"
	"time"
)

const (
	Version = 1

	// DefaultChunkSize is the plaintext chunk size used for transfers.
	DefaultChunkSize int64 = 4 << 20
	// MaxChunkSize bounds the plaintext chunk size a receiver accepts.
	MaxChunkSize int64 = 16 << 20
	// AEADOverhead is the GCM tag size appended to each encrypted chunk.
	AEADOverhead = 16
)

// DeviceInfo is the public view of a registered device.
type DeviceInfo struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Platform  string    `json:"platform"`
	PublicKey string    `json:"public_key"` // base64 X25519 public key
	Online    bool      `json:"online"`
	LastSeen  time.Time `json:"last_seen"`
	CreatedAt time.Time `json:"created_at"`
	// LAN lists the device's direct LAN endpoints (http://ip:port), reported
	// by the device itself via a "hello" frame while it is online.
	LAN []string `json:"lan,omitempty"`
}

// Hello is sent by a client after connecting ("hello" envelope).
type Hello struct {
	LAN []string `json:"lan,omitempty"`
}

// Envelope is the frame exchanged over the /api/v1/ws websocket.
//
// Server -> client types: "devices", "presence", "signal", "error", "pong".
// Client -> server types: "signal", "ping".
type Envelope struct {
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"`
	From    string          `json:"from,omitempty"`
	To      string          `json:"to,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

// Presence is the payload of a "presence" envelope.
type Presence struct {
	DeviceID string `json:"device_id"`
	Online   bool   `json:"online"`
}

// ErrorPayload is the payload of an "error" envelope.
type ErrorPayload struct {
	Code    string `json:"code"` // offline | unknown_device | bad_request
	Message string `json:"message,omitempty"`
}

// Signal kinds carried inside "signal" envelopes. The gateway never inspects
// them; they are end-to-end between devices.
const (
	KindOffer  = "offer"
	KindAnswer = "answer"
	KindDone   = "done"
	KindCancel = "cancel"
	KindRTC    = "webrtc" // reserved for P2: SDP / ICE exchange
)

// Signal is the device-to-device payload of a "signal" envelope.
type Signal struct {
	Kind   string          `json:"kind"`
	Offer  *Offer          `json:"offer,omitempty"`
	Answer *Answer         `json:"answer,omitempty"`
	Done   *Done           `json:"done,omitempty"`
	Cancel *Cancel         `json:"cancel,omitempty"`
	RTC    json.RawMessage `json:"webrtc,omitempty"`
}

// FileEntry describes one file inside a transfer manifest.
type FileEntry struct {
	Index   int    `json:"index"`
	Path    string `json:"path"` // relative, '/'-separated
	Size    int64  `json:"size"`
	ModTime int64  `json:"mtime"` // unix milliseconds
	SHA256  string `json:"sha256"`
}

// Offer starts (or resumes) a transfer session.
type Offer struct {
	TransferID   string      `json:"transfer_id"`
	Session      string      `json:"session"`
	Title        string      `json:"title"`
	ChunkSize    int64       `json:"chunk_size"`
	TotalSize    int64       `json:"total_size"`
	Files        []FileEntry `json:"files"`
	Dirs         []string    `json:"dirs,omitempty"`  // empty directories
	EphemeralKey string      `json:"ephemeral_key"`   // base64 X25519
	Routes       []string    `json:"routes"`          // "relay" (P0), "lan", "webrtc"
	Relay        string      `json:"relay,omitempty"` // relay node id chosen by the sender
	Route        string      `json:"route,omitempty"` // "lan" | "relay" (default)
	CreatedAt    time.Time   `json:"created_at"`
}

// NeedRange is a half-open range of chunk indices [From, To) of one file.
type NeedRange struct {
	File int   `json:"file"`
	From int64 `json:"from"`
	To   int64 `json:"to"`
}

// Answer is the receiver's response to an Offer.
type Answer struct {
	TransferID string      `json:"transfer_id"`
	Session    string      `json:"session"`
	Accept     bool        `json:"accept"`
	Reason     string      `json:"reason,omitempty"` // declined | busy | invalid
	Route      string      `json:"route,omitempty"`
	Need       []NeedRange `json:"need,omitempty"`
}

// Done reports the final state of a session from the receiver.
type Done struct {
	TransferID string   `json:"transfer_id"`
	Session    string   `json:"session"`
	OK         bool     `json:"ok"`
	Reason     string   `json:"reason,omitempty"`
	Saved      []string `json:"saved,omitempty"`
}

// Cancel aborts a transfer permanently (either side).
type Cancel struct {
	TransferID string `json:"transfer_id"`
	Reason     string `json:"reason,omitempty"`
}

// RegisterRequest is the body of POST /api/v1/devices/register.
type RegisterRequest struct {
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	PublicKey string `json:"public_key"`
}

// RegisterResponse is returned by POST /api/v1/devices/register.
type RegisterResponse struct {
	DeviceID string `json:"device_id"`
	Token    string `json:"token"`
}

// RelaySessionRequest is the body of POST /api/v1/relay/sessions.
type RelaySessionRequest struct {
	TransferID string `json:"transfer_id"`
	Receiver   string `json:"receiver"`
}

// RelayInfo describes one relay node. When CertSHA256 is set the node uses a
// self-signed certificate and clients must pin it (hex SHA-256 of leaf DER).
type RelayInfo struct {
	ID         string `json:"id"`
	URL        string `json:"url"`
	CertSHA256 string `json:"cert_sha256,omitempty"`
	Region     string `json:"region,omitempty"`
}

// RelayGrant is returned by POST /api/v1/relay/sessions (sender) and
// POST /api/v1/relay/tickets (receiver). The ticket authorizes the caller's
// role for this transfer on every listed relay.
type RelayGrant struct {
	Relays []RelayInfo `json:"relays"`
	Ticket string      `json:"ticket"`
}

// RelayTicketRequest is the body of POST /api/v1/relay/tickets.
type RelayTicketRequest struct {
	TransferID string `json:"transfer_id"`
}

// PairingCode is returned by POST /api/v1/pairing-codes.
type PairingCode struct {
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
}

// ICEServer mirrors the WebRTC RTCIceServer dictionary.
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}
