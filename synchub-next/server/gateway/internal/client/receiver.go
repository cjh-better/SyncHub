package client

import (
	"context"
	"crypto/cipher"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"synchub/gateway/internal/e2e"
	"synchub/gateway/internal/proto"
)

type recvFile struct {
	proto.FileEntry
	Done      []byte `json:"done"` // bitset of received chunks
	Finalized bool   `json:"finalized"`
	Final     string `json:"final,omitempty"`
}

type recvState struct {
	TransferID string            `json:"transfer_id"`
	From       string            `json:"from"`
	Digest     string            `json:"digest"`
	Title      string            `json:"title"`
	ChunkSize  int64             `json:"chunk_size"`
	Files      []recvFile        `json:"files"`
	Dirs       []string          `json:"dirs,omitempty"`
	TopMap     map[string]string `json:"top_map"`
	CreatedAt  time.Time         `json:"created_at"`

	dir   string
	mu    sync.Mutex
	dirty bool
}

func (f *recvFile) has(c int64) bool { return f.Done[c/8]&(1<<(c%8)) != 0 }
func (f *recvFile) set(c int64)      { f.Done[c/8] |= 1 << (c % 8) }

func (s *recvState) chunks(i int) int64 { return chunkCount(s.Files[i].Size, s.ChunkSize) }

func (s *recvState) complete(i int) bool {
	cc := s.chunks(i)
	for c := int64(0); c < cc; c++ {
		if !s.Files[i].has(c) {
			return false
		}
	}
	return true
}

func (s *recvState) need() ([]proto.NeedRange, int64) {
	var out []proto.NeedRange
	var bytes int64
	for i := range s.Files {
		f := &s.Files[i]
		if f.Finalized {
			continue
		}
		cc := s.chunks(i)
		for c := int64(0); c < cc; {
			if f.has(c) {
				c++
				continue
			}
			start := c
			for c < cc && !f.has(c) {
				bytes += chunkLen(f.Size, s.ChunkSize, c)
				c++
			}
			out = append(out, proto.NeedRange{File: i, From: start, To: c})
		}
	}
	return out, bytes
}

func (s *recvState) saveLocked() error {
	s.dirty = false
	return writeJSONFile(filepath.Join(s.dir, "state.json"), s)
}

func (s *recvState) partPath(i int) string { return filepath.Join(s.dir, fmt.Sprintf("f%d.part", i)) }

func validateOffer(o *proto.Offer) error {
	if !validTID(o.TransferID) || o.Session == "" || len(o.Session) > 64 {
		return errors.New("bad ids")
	}
	if o.ChunkSize < 64<<10 || o.ChunkSize > proto.MaxChunkSize {
		return errors.New("bad chunk size")
	}
	if len(o.Files) > 200000 || len(o.Dirs) > 200000 {
		return errors.New("too many entries")
	}
	var total int64
	seen := map[string]bool{}
	for i, f := range o.Files {
		if f.Index != i || f.Size < 0 || len(f.SHA256) != 64 {
			return errors.New("bad file entry")
		}
		if _, err := hex.DecodeString(f.SHA256); err != nil {
			return errors.New("bad sha256")
		}
		if _, err := SanitizeRelPath(f.Path); err != nil {
			return fmt.Errorf("unsafe path %q: %w", f.Path, err)
		}
		if seen[f.Path] {
			return errors.New("duplicate path")
		}
		seen[f.Path] = true
		total += f.Size
	}
	for _, d := range o.Dirs {
		if _, err := SanitizeRelPath(d); err != nil {
			return fmt.Errorf("unsafe dir %q", d)
		}
	}
	if total != o.TotalSize {
		return errors.New("total size mismatch")
	}
	return nil
}

func validTID(t string) bool {
	if len(t) < 8 || len(t) > 64 {
		return false
	}
	for _, c := range t {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func (a *Agent) loadOrInitState(o *proto.Offer, from string) (*recvState, error) {
	dir := filepath.Join(a.cfg.partialDir(), o.TransferID)
	digest := ManifestDigest(o)
	if b, err := os.ReadFile(filepath.Join(dir, "state.json")); err == nil {
		var st recvState
		if json.Unmarshal(b, &st) == nil && st.Digest == digest && st.From == from {
			st.dir = dir
			if st.TopMap == nil {
				st.TopMap = map[string]string{}
			}
			return &st, nil
		}
		_ = os.RemoveAll(dir) // different manifest: start over
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	st := &recvState{
		TransferID: o.TransferID, From: from, Digest: digest, Title: o.Title,
		ChunkSize: o.ChunkSize, Dirs: o.Dirs, TopMap: map[string]string{}, CreatedAt: time.Now().UTC(), dir: dir,
	}
	for _, f := range o.Files {
		st.Files = append(st.Files, recvFile{FileEntry: f, Done: make([]byte, (chunkCount(f.Size, o.ChunkSize)+7)/8)})
	}
	return st, st.saveLocked()
}

func (a *Agent) answer(ctx context.Context, to string, ans proto.Answer) {
	if err := a.sendSignal(ctx, to, proto.Signal{Kind: proto.KindAnswer, Answer: &ans}); err != nil {
		a.logf("[recv %s] cannot answer: %v", ans.TransferID, err)
	}
}

func (a *Agent) handleOffer(ctx context.Context, from string, o *proto.Offer) {
	reject := func(reason string) {
		a.answer(ctx, from, proto.Answer{TransferID: o.TransferID, Session: o.Session, Accept: false, Reason: reason})
	}
	if err := validateOffer(o); err != nil {
		a.logf("[recv] invalid offer from %s: %v", from, err)
		reject("invalid")
		return
	}
	dev, ok := a.device(ctx, from)
	if !ok {
		reject("invalid")
		return
	}
	senderPub, err := e2e.ParsePublic(dev.PublicKey)
	if err != nil {
		reject("invalid")
		return
	}
	aead, err := e2e.ReceiverSession(a.priv, o.EphemeralKey, senderPub, o.TransferID, o.Session)
	if err != nil {
		reject("invalid")
		return
	}
	// P0 only pairs the user's own devices: always auto-accept.

	// Supersede a running session of the same transfer.
	sctx, cancel := context.WithCancel(ctx)
	sess := &inSession{from: from, cancel: cancel, done: make(chan struct{})}
	a.mu.Lock()
	prev := a.incoming[o.TransferID]
	a.incoming[o.TransferID] = sess
	a.mu.Unlock()
	if prev != nil {
		prev.cancel()
		<-prev.done
	}
	defer func() {
		cancel()
		a.mu.Lock()
		if a.incoming[o.TransferID] == sess {
			delete(a.incoming, o.TransferID)
		}
		a.mu.Unlock()
		close(sess.done)
	}()

	st, err := a.loadOrInitState(o, from)
	if err != nil {
		a.logf("[recv %s] state: %v", o.TransferID, err)
		reject("busy")
		return
	}
	route := "lan"
	var rc *RelayConn
	if o.Route != "lan" {
		grant, err := a.api.RelayTicket(sctx, o.TransferID)
		if err != nil {
			a.logf("[recv %s] relay ticket: %v", o.TransferID, err)
			reject("busy")
			return
		}
		for _, info := range grant.Relays {
			if info.ID == o.Relay || (o.Relay == "" && rc == nil) {
				rc = a.api.Relay(info, grant.Ticket)
			}
		}
		if rc == nil {
			a.logf("[recv %s] sender chose unknown relay %q", o.TransferID, o.Relay)
			reject("busy")
			return
		}
		route = "relay:" + rc.ID
	} else if a.lan == nil {
		reject("busy") // sender believes we listen on LAN but we don't
		return
	}
	need, needBytes := st.need()
	tp := a.trackProgress(Progress{TransferID: o.TransferID, Direction: "recv", Peer: dev.Name, Title: o.Title, Route: route, Done: o.TotalSize - needBytes, Total: o.TotalSize})
	sk := a.newSink(sctx, st, aead, o.Session, need, tp)
	defer a.dropSink(sk)
	a.answer(sctx, from, proto.Answer{TransferID: o.TransferID, Session: o.Session, Accept: true, Route: route, Need: need})
	a.logf("[recv %s] ← %s: %q %s, %d files, need %s via %s", o.TransferID, dev.Name, o.Title, human(o.TotalSize), len(o.Files), human(needBytes), route)

	done := func(ok bool, reason string, saved []string) {
		_ = a.sendSignal(ctx, from, proto.Signal{Kind: proto.KindDone, Done: &proto.Done{TransferID: o.TransferID, Session: o.Session, OK: ok, Reason: reason, Saved: saved}})
	}
	if rc != nil {
		go a.fetchFromRelay(sk, rc)
	}
	err = sk.wait()
	st.mu.Lock()
	_ = st.saveLocked()
	st.mu.Unlock()
	if err != nil {
		if sctx.Err() == nil {
			a.logf("[recv %s] session failed: %v", o.TransferID, err)
			done(false, err.Error(), nil)
		}
		return
	}
	saved, err := a.finalizeAll(st)
	if err != nil {
		a.logf("[recv %s] finalize: %v", o.TransferID, err)
		done(false, err.Error(), nil)
		return
	}
	done(true, "", saved)
	_ = os.RemoveAll(st.dir)
	a.logf("[recv %s] complete: %d item(s) saved under %s", o.TransferID, len(saved), a.cfg.RecvDir)
	a.finish(Result{TransferID: o.TransferID, Direction: "recv", OK: true, Saved: saved})
}

var (
	errHashMismatch = errors.New("file hash mismatch")
	errUnexpected   = errors.New("chunk not expected in this session")
	errBadChunk     = errors.New("chunk failed authentication or length check")
)

// sink receives the chunks of one session, from relay workers or LAN pushes.
type sink struct {
	a       *Agent
	st      *recvState
	aead    cipher.AEAD
	session string
	tp      *transferProgress

	ctx    context.Context
	cancel context.CancelCauseFunc

	mu      sync.Mutex
	pending map[chunkRef]bool
	order   []chunkRef
	handles map[int]*os.File
	left    int
	allDone chan struct{}
	last    atomic.Int64 // unix nanos of last accepted chunk
}

func (a *Agent) newSink(ctx context.Context, st *recvState, aead cipher.AEAD, session string, need []proto.NeedRange, tp *transferProgress) *sink {
	ctx, cancel := context.WithCancelCause(ctx)
	s := &sink{a: a, st: st, aead: aead, session: session, tp: tp, ctx: ctx, cancel: cancel,
		pending: map[chunkRef]bool{}, handles: map[int]*os.File{}, allDone: make(chan struct{})}
	for _, n := range need {
		for c := n.From; c < n.To; c++ {
			r := chunkRef{n.File, c}
			s.pending[r] = true
			s.order = append(s.order, r)
		}
	}
	s.left = len(s.order)
	if s.left == 0 {
		close(s.allDone)
	}
	s.last.Store(time.Now().UnixNano())
	a.mu.Lock()
	if a.sinks == nil {
		a.sinks = map[string]*sink{}
	}
	a.sinks[st.TransferID+"|"+session] = s
	a.mu.Unlock()
	go s.flushLoop()
	return s
}

func (a *Agent) dropSink(s *sink) {
	a.mu.Lock()
	delete(a.sinks, s.st.TransferID+"|"+s.session)
	a.mu.Unlock()
	s.cancel(context.Canceled)
	s.mu.Lock()
	for i, f := range s.handles {
		f.Close()
		delete(s.handles, i)
	}
	s.mu.Unlock()
}

func (a *Agent) lookupSink(tid, session string) *sink {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.sinks[tid+"|"+session]
}

func (s *sink) flushLoop() {
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-t.C:
			s.st.mu.Lock()
			if s.st.dirty {
				_ = s.st.saveLocked()
			}
			s.st.mu.Unlock()
		}
	}
}

// wait blocks until every needed chunk arrived (nil), the session failed, or
// nothing arrived for 90 seconds.
func (s *sink) wait() error {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.allDone:
			return nil
		case <-s.ctx.Done():
			return context.Cause(s.ctx)
		case <-t.C:
			if time.Since(time.Unix(0, s.last.Load())) > 90*time.Second {
				return errors.New("no data received for 90s")
			}
		}
	}
}

func (s *sink) file(i int) (*os.File, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if f := s.handles[i]; f != nil {
		return f, nil
	}
	f, err := os.OpenFile(s.st.partPath(i), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	s.handles[i] = f
	return f, nil
}

// accept decrypts, writes and records one chunk. errUnexpected and
// errBadChunk leave the session running (callers decide); other errors
// (disk full, hash mismatch) fail the session.
func (s *sink) accept(r chunkRef, sealed []byte) error {
	s.mu.Lock()
	ok := s.pending[r]
	s.mu.Unlock()
	if !ok {
		return errUnexpected
	}
	if r.file < 0 || r.file >= len(s.st.Files) {
		return errUnexpected
	}
	want := chunkLen(s.st.Files[r.file].Size, s.st.ChunkSize, r.chunk)
	plain, err := e2e.Open(s.aead, s.st.TransferID, s.session, r.file, r.chunk, sealed)
	if err != nil || int64(len(plain)) != want {
		return errBadChunk
	}
	f, err := s.file(r.file)
	if err == nil {
		_, err = f.WriteAt(plain, r.chunk*s.st.ChunkSize)
	}
	if err != nil {
		s.cancel(err) // e.g. disk full: session fails, progress is kept
		return err
	}
	s.mu.Lock()
	if !s.pending[r] { // duplicate delivered concurrently
		s.mu.Unlock()
		return nil
	}
	delete(s.pending, r)
	s.left--
	left := s.left
	s.mu.Unlock()
	s.last.Store(time.Now().UnixNano())
	s.tp.done.Add(want)
	s.st.mu.Lock()
	s.st.Files[r.file].set(r.chunk)
	s.st.dirty = true
	complete := s.st.complete(r.file)
	s.st.mu.Unlock()
	if complete {
		s.mu.Lock()
		if h := s.handles[r.file]; h != nil {
			h.Close()
			delete(s.handles, r.file)
		}
		s.mu.Unlock()
		if err := s.a.verifyPart(s.st, r.file); err != nil {
			s.cancel(err)
			return err
		}
	}
	if left == 0 {
		close(s.allDone)
	}
	return nil
}

// fetchFromRelay pulls the session's chunks from a relay with N workers.
func (a *Agent) fetchFromRelay(s *sink, rc *RelayConn) {
	var next atomic.Int64
	var wg sync.WaitGroup
	for w := 0; w < a.opt.Workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := next.Add(1) - 1
				if i >= int64(len(s.order)) || s.ctx.Err() != nil {
					return
				}
				r := s.order[i]
				want := chunkLen(s.st.Files[r.file].Size, s.st.ChunkSize, r.chunk)
				sealed, err := a.getWithRetry(s.ctx, rc, s.st.TransferID, s.session, r, want+proto.AEADOverhead)
				if err != nil {
					s.cancel(err)
					return
				}
				if err := s.accept(r, sealed); err != nil && !errors.Is(err, errUnexpected) {
					s.cancel(fmt.Errorf("chunk %d/%d: %w", r.file, r.chunk, err))
					return
				}
			}
		}()
	}
	wg.Wait()
}

// verifyPart checks the SHA-256 of a completed part; on mismatch the file's
// progress is reset so the next session refetches it.
func (a *Agent) verifyPart(st *recvState, i int) error {
	f := &st.Files[i]
	h, err := hashFile(st.partPath(i), nil)
	if err != nil {
		return err
	}
	if h == f.SHA256 {
		return nil
	}
	st.mu.Lock()
	for k := range f.Done {
		f.Done[k] = 0
	}
	_ = st.saveLocked()
	st.mu.Unlock()
	_ = os.Remove(st.partPath(i))
	return fmt.Errorf("%w: %s", errHashMismatch, f.Path)
}

func (a *Agent) getWithRetry(ctx context.Context, rc *RelayConn, tid, session string, r chunkRef, max int64) ([]byte, error) {
	timeouts, fails := 0, 0
	for {
		b, err := rc.GetChunk(ctx, tid, session, r.file, r.chunk, max)
		if err == nil {
			return b, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		switch {
		case IsStatus(err, 504):
			if timeouts++; timeouts > 8 {
				return nil, fmt.Errorf("sender stopped sending: %w", err)
			}
			continue
		case IsStatus(err, 403), IsStatus(err, 401), IsStatus(err, 400):
			return nil, err
		}
		if fails++; fails > 6 {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Duration(min(fails*fails, 10)) * time.Second):
		}
	}
}

// finalizeAll moves completed parts into the receive directory, preserving
// folder structure. Same-name conflicts get "name (n).ext".
func (a *Agent) finalizeAll(st *recvState) ([]string, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if err := os.MkdirAll(a.cfg.RecvDir, 0o755); err != nil {
		return nil, err
	}
	topDest := func(top string, isDir bool) string {
		if v, ok := st.TopMap[top]; ok {
			return v
		}
		p := filepath.Join(a.cfg.RecvDir, top)
		if isDir {
			p = uniquePath(p)
		}
		st.TopMap[top] = filepath.Base(p)
		return st.TopMap[top]
	}
	var saved []string
	addSaved := func(p string) {
		for _, s := range saved {
			if s == p {
				return
			}
		}
		saved = append(saved, p)
	}
	for i := range st.Files {
		f := &st.Files[i]
		if f.Finalized {
			addSaved(f.Final)
			continue
		}
		if !st.complete(i) {
			return nil, fmt.Errorf("incomplete file %s", f.Path)
		}
		comps, _ := SanitizeRelPath(f.Path)
		part := st.partPath(i)
		if f.Size == 0 {
			if err := os.WriteFile(part, nil, 0o644); err != nil {
				return nil, err
			}
		}
		var dest string
		if len(comps) == 1 {
			dest = filepath.Join(a.cfg.RecvDir, comps[0])
			if fi, err := os.Stat(dest); err == nil && fi.Size() == f.Size {
				if h, _ := hashFile(dest, nil); h == f.SHA256 {
					_ = os.Remove(part) // identical file already there
					f.Finalized, f.Final = true, dest
					addSaved(dest)
					continue
				}
			}
			dest = uniquePath(dest)
		} else {
			top := topDest(comps[0], true)
			dest = filepath.Join(append([]string{a.cfg.RecvDir, top}, comps[1:]...)...)
			if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
				return nil, err
			}
			dest = uniquePath(dest)
			addSaved(filepath.Join(a.cfg.RecvDir, top))
		}
		if err := os.Rename(part, dest); err != nil {
			return nil, err
		}
		mt := time.UnixMilli(f.ModTime)
		_ = os.Chtimes(dest, mt, mt)
		f.Finalized, f.Final = true, dest
		if len(comps) == 1 {
			addSaved(dest)
		}
		_ = st.saveLocked()
	}
	for _, d := range st.Dirs {
		comps, _ := SanitizeRelPath(d)
		top := topDest(comps[0], true)
		p := filepath.Join(append([]string{a.cfg.RecvDir, top}, comps[1:]...)...)
		if err := os.MkdirAll(p, 0o755); err != nil {
			return nil, err
		}
		addSaved(filepath.Join(a.cfg.RecvDir, top))
	}
	_ = st.saveLocked()
	return saved, nil
}

func (a *Agent) onCancel(from string, c *proto.Cancel) {
	a.mu.Lock()
	s := a.incoming[c.TransferID]
	outCancel := a.activeOut[c.TransferID]
	peer := a.outPeer[c.TransferID]
	a.mu.Unlock()
	if s != nil && s.from == from {
		s.cancel()
		<-s.done
		_ = os.RemoveAll(filepath.Join(a.cfg.partialDir(), c.TransferID))
		a.finish(Result{TransferID: c.TransferID, Direction: "recv", Err: "cancelled by sender: " + c.Reason})
	}
	if peer == from {
		if outCancel != nil {
			outCancel()
		}
		a.removeOutbox(c.TransferID)
		a.finish(Result{TransferID: c.TransferID, Direction: "send", Err: "cancelled by receiver: " + c.Reason})
	}
}

// CancelOutgoing aborts an outgoing transfer and notifies the receiver.
func (a *Agent) CancelOutgoing(ctx context.Context, tid string) error {
	a.mu.Lock()
	c := a.activeOut[tid]
	peer := a.outPeer[tid]
	a.mu.Unlock()
	if c != nil {
		c()
	}
	a.removeOutbox(tid)
	if peer != "" {
		return a.sendSignal(ctx, peer, proto.Signal{Kind: proto.KindCancel, Cancel: &proto.Cancel{TransferID: tid, Reason: "user"}})
	}
	return nil
}
