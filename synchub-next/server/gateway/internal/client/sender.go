package client

import (
	"context"
	"crypto/cipher"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"synchub/gateway/internal/e2e"
	"synchub/gateway/internal/proto"
)

// OutEntry is a persisted outgoing transfer (survives restarts).
type OutEntry struct {
	TransferID string      `json:"transfer_id"`
	To         string      `json:"to"`
	Title      string      `json:"title"`
	ChunkSize  int64       `json:"chunk_size"`
	Files      []LocalFile `json:"files"`
	Dirs       []string    `json:"dirs,omitempty"`
	CreatedAt  time.Time   `json:"created_at"`
}

func (e *OutEntry) total() int64 {
	var t int64
	for _, f := range e.Files {
		t += f.Size
	}
	return t
}

const leaseFresh = 20 * time.Second

// Enqueue hashes the selection and stores it in the outbox.
func (a *Agent) Enqueue(paths []string, to string, onHash func(done, total int64)) (*OutEntry, error) {
	files, dirs, err := BuildManifest(paths, onHash)
	if err != nil {
		return nil, err
	}
	if len(files) == 0 && len(dirs) == 0 {
		return nil, errors.New("nothing to send")
	}
	title := filepath.Base(paths[0])
	if len(paths) > 1 {
		title = fmt.Sprintf("%s 等 %d 项", title, len(paths))
	}
	e := &OutEntry{
		TransferID: NewTransferID(), To: to, Title: title, ChunkSize: proto.DefaultChunkSize,
		Files: files, Dirs: dirs, CreatedAt: time.Now().UTC(),
	}
	return e, writeJSONFile(filepath.Join(a.cfg.outboxDir(), e.TransferID+".json"), e)
}

// HoldLease marks an outbox entry as owned by this process (send mode) so a
// background daemon using the same identity does not drive it concurrently.
func (a *Agent) HoldLease(ctx context.Context, tid string) {
	p := filepath.Join(a.cfg.outboxDir(), tid+".lease")
	touch := func() { _ = os.WriteFile(p, []byte(time.Now().Format(time.RFC3339)), 0o600) }
	touch()
	go func() {
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		defer os.Remove(p)
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				touch()
			}
		}
	}()
}

func (a *Agent) loadOutbox() []*OutEntry {
	ents, _ := os.ReadDir(a.cfg.outboxDir())
	var out []*OutEntry
	for _, de := range ents {
		name := de.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(a.cfg.outboxDir(), name))
		if err != nil {
			continue
		}
		var e OutEntry
		if json.Unmarshal(b, &e) == nil && e.TransferID != "" {
			out = append(out, &e)
		}
	}
	return out
}

func (a *Agent) removeOutbox(tid string) {
	_ = os.Remove(filepath.Join(a.cfg.outboxDir(), tid+".json"))
}

func (a *Agent) leaseHeldElsewhere(tid string) bool {
	if a.opt.OnlyTransfer == tid {
		return false
	}
	st, err := os.Stat(filepath.Join(a.cfg.outboxDir(), tid+".lease"))
	return err == nil && time.Since(st.ModTime()) < leaseFresh
}

func (a *Agent) scheduler(ctx context.Context) {
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	for {
		a.scheduleOnce(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-a.wake:
		}
	}
}

func (a *Agent) scheduleOnce(ctx context.Context) {
	a.mu.Lock()
	connected := a.conn != nil
	a.mu.Unlock()
	if !connected {
		return
	}
	for _, e := range a.loadOutbox() {
		if a.opt.OnlyTransfer != "" && e.TransferID != a.opt.OnlyTransfer {
			continue
		}
		if a.leaseHeldElsewhere(e.TransferID) {
			continue
		}
		a.mu.Lock()
		a.outPeer[e.TransferID] = e.To
		_, active := a.activeOut[e.TransferID]
		next := a.nextTry[e.TransferID]
		d, known := a.devices[e.To]
		a.mu.Unlock()
		if active || time.Now().Before(next) {
			continue
		}
		if known && !d.Online {
			continue
		}
		sctx, cancel := context.WithCancel(ctx)
		a.mu.Lock()
		a.activeOut[e.TransferID] = cancel
		a.mu.Unlock()
		go func(e *OutEntry) {
			defer cancel()
			err := a.runOutgoing(sctx, e)
			a.mu.Lock()
			delete(a.activeOut, e.TransferID)
			if err != nil {
				b := a.backoff[e.TransferID]
				if b == 0 {
					b = 2 * time.Second
				} else if b < time.Minute {
					b *= 2
				}
				a.backoff[e.TransferID] = b
				a.nextTry[e.TransferID] = time.Now().Add(b)
			} else {
				delete(a.backoff, e.TransferID)
				delete(a.nextTry, e.TransferID)
				delete(a.outPeer, e.TransferID)
			}
			a.mu.Unlock()
			if err != nil && ctx.Err() == nil {
				a.logf("[send %s] session ended: %v (will retry)", e.TransferID, err)
			}
		}(e)
	}
}

type chunkRef struct {
	file  int
	chunk int64
}

func expandNeed(files []LocalFile, chunkSize int64, need []proto.NeedRange) ([]chunkRef, int64, error) {
	var out []chunkRef
	var bytes int64
	for _, n := range sortedNeed(need) {
		if n.File < 0 || n.File >= len(files) {
			return nil, 0, fmt.Errorf("need: bad file index %d", n.File)
		}
		cc := chunkCount(files[n.File].Size, chunkSize)
		if n.From < 0 || n.To > cc || n.From >= n.To {
			return nil, 0, fmt.Errorf("need: bad range %d..%d of %d", n.From, n.To, cc)
		}
		for c := n.From; c < n.To; c++ {
			out = append(out, chunkRef{n.File, c})
			bytes += chunkLen(files[n.File].Size, chunkSize, c)
		}
	}
	return out, bytes, nil
}

func chunkLen(size, cs, c int64) int64 {
	if rem := size - c*cs; rem < cs {
		return rem
	}
	return cs
}

// runOutgoing performs one offer/answer/push/done session. A nil return means
// the transfer is finished (delivered or permanently failed).
func (a *Agent) runOutgoing(ctx context.Context, e *OutEntry) error {
	tid := e.TransferID
	dev, ok := a.device(ctx, e.To)
	if !ok {
		a.removeOutbox(tid)
		a.finish(Result{TransferID: tid, Direction: "send", Err: "receiver device no longer exists"})
		return nil
	}
	pub, err := e2e.ParsePublic(dev.PublicKey)
	if err != nil {
		return err
	}
	// The source must be unchanged since it was hashed.
	for _, f := range e.Files {
		st, err := os.Stat(f.Abs)
		if err != nil || st.Size() != f.Size || st.ModTime().UnixMilli() != f.ModTime {
			a.removeOutbox(tid)
			a.finish(Result{TransferID: tid, Direction: "send", Err: "source file changed or missing: " + f.Path})
			return nil
		}
	}
	session := randToken(9)
	ephPub, aead, err := e2e.SenderSession(a.priv, pub, tid, session)
	if err != nil {
		return err
	}
	var pusher chunkPusher
	relayID, route := "", "relay"
	if !a.relayBad(tid, "lan") {
		if lc := probeLAN(ctx, dev); lc != nil {
			pusher, route = lc, "lan"
		}
	}
	if pusher == nil {
		grant, err := a.api.OpenRelay(ctx, tid, e.To)
		if err != nil {
			return fmt.Errorf("open relay: %w", err)
		}
		rc, err := a.pickRelay(ctx, tid, grant)
		if err != nil {
			return err
		}
		pusher, relayID = rc, rc.ID
	}
	ansCh, unA := a.waitFor("answer:" + tid + ":" + session)
	defer unA()
	doneCh, unD := a.waitFor("done:" + tid + ":" + session)
	defer unD()

	files := make([]proto.FileEntry, len(e.Files))
	for i, f := range e.Files {
		files[i] = f.FileEntry
	}
	offer := &proto.Offer{
		TransferID: tid, Session: session, Title: e.Title, ChunkSize: e.ChunkSize,
		TotalSize: e.total(), Files: files, Dirs: e.Dirs, EphemeralKey: ephPub,
		Routes: []string{"lan", "relay"}, Relay: relayID, Route: route, CreatedAt: e.CreatedAt,
	}
	if err := a.sendSignal(ctx, e.To, proto.Signal{Kind: proto.KindOffer, Offer: offer}); err != nil {
		return err
	}
	var ans *proto.Answer
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(60 * time.Second):
		return errors.New("no answer from receiver")
	case s := <-ansCh:
		ans = s.Answer
	}
	if !ans.Accept {
		if ans.Reason == "declined" || ans.Reason == "invalid" {
			a.removeOutbox(tid)
			a.finish(Result{TransferID: tid, Direction: "send", Err: "receiver " + ans.Reason})
			return nil
		}
		return errors.New("receiver busy: " + ans.Reason)
	}
	chunks, needBytes, err := expandNeed(e.Files, e.ChunkSize, ans.Need)
	if err != nil {
		return err
	}
	total := e.total()
	tp := a.trackProgress(Progress{TransferID: tid, Direction: "send", Peer: dev.Name, Title: e.Title, Route: pusher.Name(), Done: total - needBytes, Total: total})
	if len(chunks) > 0 {
		a.logf("[send %s] → %s: %d chunks (%s) via %s, resuming at %.1f%%", tid, dev.Name, len(chunks), human(needBytes), pusher.Name(), 100*float64(total-needBytes)/float64(max(total, 1)))
	}

	pctx, pcancel := context.WithCancelCause(ctx)
	defer pcancel(nil)
	// This goroutine is the only consumer of doneCh. An early "done" with
	// ok=false (receiver aborted) stops the push.
	var early atomic.Pointer[proto.Done]
	gotDone := make(chan struct{})
	go func() {
		select {
		case s := <-doneCh:
			early.Store(s.Done)
			close(gotDone)
			if !s.Done.OK {
				pcancel(errors.New("receiver ended session"))
			}
		case <-ctx.Done():
		}
	}()

	if err := a.push(pctx, pusher, e, aead, session, chunks, tp); err != nil && early.Load() == nil {
		if route == "lan" {
			a.markRelayBad(tid, "lan")
		} else {
			a.markRelayBad(tid, relayID)
		}
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(10 * time.Minute):
		return errors.New("timeout waiting for receiver confirmation")
	case <-gotDone:
	}
	done := early.Load()
	if !done.OK {
		return errors.New("receiver reported: " + done.Reason)
	}
	a.removeOutbox(tid)
	a.finish(Result{TransferID: tid, Direction: "send", OK: true, Saved: done.Saved})
	return nil
}

func (a *Agent) push(ctx context.Context, rc chunkPusher, e *OutEntry, aead cipher.AEAD, session string, chunks []chunkRef, tp *transferProgress) error {
	var next atomic.Int64
	var wg sync.WaitGroup
	errCh := make(chan error, a.opt.Workers)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	for w := 0; w < a.opt.Workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			open := map[int]*os.File{}
			defer func() {
				for _, f := range open {
					f.Close()
				}
			}()
			buf := make([]byte, e.ChunkSize)
			for {
				i := next.Add(1) - 1
				if i >= int64(len(chunks)) || ctx.Err() != nil {
					return
				}
				c := chunks[i]
				lf := e.Files[c.file]
				f := open[c.file]
				if f == nil {
					var err error
					if f, err = os.Open(lf.Abs); err != nil {
						errCh <- err
						cancel()
						return
					}
					open[c.file] = f
				}
				n := chunkLen(lf.Size, e.ChunkSize, c.chunk)
				if _, err := f.ReadAt(buf[:n], c.chunk*e.ChunkSize); err != nil && !errors.Is(err, io.EOF) {
					errCh <- err
					cancel()
					return
				}
				if err := a.limiter.wait(ctx, int(n)); err != nil {
					return
				}
				sealed := e2e.Seal(aead, e.TransferID, session, c.file, c.chunk, buf[:n])
				if err := a.putWithRetry(ctx, rc, e.TransferID, session, c, sealed); err != nil {
					errCh <- err
					cancel()
					return
				}
				tp.done.Add(n)
			}
		}()
	}
	wg.Wait()
	select {
	case err := <-errCh:
		return err
	default:
	}
	return context.Cause(ctx)
}

// pickRelay probes all advertised relays in parallel and returns the fastest
// healthy one, skipping relays that recently failed for this transfer.
func (a *Agent) pickRelay(ctx context.Context, tid string, g *proto.RelayGrant) (*RelayConn, error) {
	if len(g.Relays) == 0 {
		return nil, errors.New("gateway advertised no relays")
	}
	type res struct {
		rc  *RelayConn
		rtt time.Duration
		err error
	}
	pctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	out := make(chan res, len(g.Relays))
	for _, info := range g.Relays {
		rc := a.api.Relay(info, g.Ticket)
		go func() {
			// The first request pays for TCP+TLS setup; measure a warm
			// round trip so a reused gateway connection is not favoured.
			_, err := rc.Ping(pctx)
			var rtt time.Duration
			if err == nil {
				rtt, err = rc.Ping(pctx)
			}
			out <- res{rc, rtt, err}
		}()
	}
	var best, fallback *RelayConn
	var bestRTT time.Duration
	for range g.Relays {
		r := <-out
		if r.err != nil {
			a.logf("[send %s] relay %s unreachable: %v", tid, r.rc.ID, r.err)
			continue
		}
		if a.relayBad(tid, r.rc.ID) {
			fallback = r.rc
			continue
		}
		if best == nil || r.rtt < bestRTT {
			best, bestRTT = r.rc, r.rtt
		}
		a.logf("[send %s] relay %s rtt %s", tid, r.rc.ID, r.rtt.Round(time.Millisecond))
	}
	if best == nil {
		best = fallback
	}
	if best == nil {
		return nil, errors.New("no relay reachable")
	}
	return best, nil
}

func (a *Agent) markRelayBad(tid, id string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.badRelay == nil {
		a.badRelay = map[string]time.Time{}
	}
	a.badRelay[tid+"|"+id] = time.Now().Add(2 * time.Minute)
}

func (a *Agent) relayBad(tid, id string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return time.Now().Before(a.badRelay[tid+"|"+id])
}

func (a *Agent) putWithRetry(ctx context.Context, rc chunkPusher, tid, session string, c chunkRef, data []byte) error {
	timeouts, fails := 0, 0
	for {
		err := rc.PutChunk(ctx, tid, session, c.file, c.chunk, data)
		if err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		switch {
		case IsStatus(err, 504):
			if timeouts++; timeouts > 8 {
				return fmt.Errorf("receiver stopped fetching: %w", err)
			}
			continue
		case IsStatus(err, 403), IsStatus(err, 401), IsStatus(err, 400), IsStatus(err, 404), IsStatus(err, 409), IsStatus(err, 500):
			return err
		}
		if fails++; fails > 6 {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(min(fails*fails, 10)) * time.Second):
		}
	}
}

func human(n int64) string {
	const u = 1024
	if n < u {
		return fmt.Sprintf("%d B", n)
	}
	d, e := int64(u), 0
	for m := n / u; m >= u; m /= u {
		d *= u
		e++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(d), "KMGTPE"[e])
}

// Human formats a byte count.
func Human(n int64) string { return human(n) }
