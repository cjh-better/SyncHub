package client

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"synchub/gateway/internal/proto"
)

// LocalFile is a manifest entry plus the sender-side absolute path.
type LocalFile struct {
	proto.FileEntry
	Abs string `json:"abs"`
}

// BuildManifest walks the given files/folders. A folder argument keeps its
// own name as the top-level path component, like dragging it into Blip.
func BuildManifest(paths []string, progress func(done, total int64)) ([]LocalFile, []string, error) {
	var files []LocalFile
	var dirs []string
	seen := map[string]bool{}
	for _, p := range paths {
		abs, err := filepath.Abs(p)
		if err != nil {
			return nil, nil, err
		}
		st, err := os.Stat(abs)
		if err != nil {
			return nil, nil, err
		}
		base := filepath.Base(abs)
		if !st.IsDir() {
			files = append(files, LocalFile{FileEntry: proto.FileEntry{Path: base, Size: st.Size(), ModTime: st.ModTime().UnixMilli()}, Abs: abs})
			continue
		}
		err = filepath.WalkDir(abs, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			rel, _ := filepath.Rel(abs, path)
			relSlash := base
			if rel != "." {
				relSlash = base + "/" + filepath.ToSlash(rel)
			}
			if d.IsDir() {
				ents, _ := os.ReadDir(path)
				if len(ents) == 0 {
					dirs = append(dirs, relSlash)
				}
				return nil
			}
			if !d.Type().IsRegular() {
				return nil // skip symlinks, sockets, ...
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			files = append(files, LocalFile{FileEntry: proto.FileEntry{Path: relSlash, Size: info.Size(), ModTime: info.ModTime().UnixMilli()}, Abs: path})
			return nil
		})
		if err != nil {
			return nil, nil, err
		}
	}
	for _, f := range files {
		k := strings.ToLower(f.Path)
		if seen[k] {
			return nil, nil, fmt.Errorf("duplicate path in selection: %s", f.Path)
		}
		seen[k] = true
	}
	var total, done int64
	for _, f := range files {
		total += f.Size
	}
	for i := range files {
		files[i].Index = i
		h, err := hashFile(files[i].Abs, func(n int64) {
			done += n
			if progress != nil {
				progress(done, total)
			}
		})
		if err != nil {
			return nil, nil, err
		}
		files[i].SHA256 = h
	}
	return files, dirs, nil
}

type countingWriter struct{ fn func(int64) }

func (c countingWriter) Write(p []byte) (int, error) { c.fn(int64(len(p))); return len(p), nil }

func hashFile(path string, onBytes func(int64)) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	var w io.Writer = h
	if onBytes != nil {
		w = io.MultiWriter(h, countingWriter{onBytes})
	}
	if _, err := io.CopyBuffer(w, f, make([]byte, 1<<20)); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func chunkCount(size, chunk int64) int64 {
	if size == 0 {
		return 0
	}
	return (size + chunk - 1) / chunk
}

// ManifestDigest identifies a manifest so a receiver can tell whether a
// re-offer is the same transfer it has partial state for.
func ManifestDigest(o *proto.Offer) string {
	b, _ := json.Marshal(struct {
		C int64             `json:"c"`
		F []proto.FileEntry `json:"f"`
		D []string          `json:"d"`
	}{o.ChunkSize, o.Files, o.Dirs})
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

var reserved = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true, "COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true, "LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

// SanitizeRelPath turns an untrusted '/'-separated path from a manifest into
// safe path components. It rejects traversal and absolute paths, and maps
// characters that are illegal on Windows.
func SanitizeRelPath(p string) ([]string, error) {
	if p == "" || !utf8.ValidString(p) || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") || strings.Contains(p, "\x00") {
		return nil, errors.New("invalid path")
	}
	parts := strings.Split(p, "/")
	if len(parts) > 64 {
		return nil, errors.New("path too deep")
	}
	out := make([]string, 0, len(parts))
	for i, c := range parts {
		if c == "" || c == "." || c == ".." {
			return nil, errors.New("invalid path component")
		}
		if i == 0 && len(c) == 2 && c[1] == ':' {
			return nil, errors.New("drive letter")
		}
		c = strings.Map(func(r rune) rune {
			if r < 0x20 || strings.ContainsRune(`<>:"|?*`, r) {
				return '_'
			}
			return r
		}, c)
		c = strings.TrimRight(c, ". ")
		if c == "" {
			c = "_"
		}
		stem := strings.ToUpper(strings.SplitN(c, ".", 2)[0])
		if reserved[stem] {
			c = "_" + c
		}
		if len(c) > 255 {
			return nil, errors.New("component too long")
		}
		out = append(out, c)
	}
	return out, nil
}

// uniquePath returns path, or "name (n).ext" if it already exists.
func uniquePath(path string) string {
	if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
		return path
	}
	dir, file := filepath.Split(path)
	ext := filepath.Ext(file)
	stem := strings.TrimSuffix(file, ext)
	for i := 1; ; i++ {
		p := filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
		if _, err := os.Lstat(p); errors.Is(err, os.ErrNotExist) {
			return p
		}
	}
}

func sortedNeed(n []proto.NeedRange) []proto.NeedRange {
	sort.Slice(n, func(i, j int) bool {
		if n[i].File != n[j].File {
			return n[i].File < n[j].File
		}
		return n[i].From < n[j].From
	})
	return n
}
