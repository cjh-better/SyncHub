// OutboxCore.swift — Foundation-only (compiles / tests on Linux):
//  * FolderOutbox: finds files newly placed in the transfer folder that should be sent automatically
//  * ClipFilePlan: what to do with files copied in Finder (⌘C)
//  * OwnClipPushes: remembers files / images this Mac put on the shared clipboard, so their history copy
//    (which the server lists as coming from "Clipboard") is not downloaded straight back into the transfer folder.
import Foundation

// MARK: - Own clipboard pushes (echo guard for the auto-receiver)

final class OwnClipPushes {
    static let shared = OwnClipPushes()
    var ttl: TimeInterval = 3600
    private var entries: [(name: String, size: Int64, at: Date)] = []
    private let lock = NSLock()

    func note(name: String, size: Int64, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { now.timeIntervalSince($0.at) > ttl || ($0.name == name && $0.size == size) }
        entries.append((name, size, now))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    /// True for a hub history item that is this Mac's own clipboard file / image coming back.
    func matches(_ item: HubItem, now: Date = Date()) -> Bool {
        guard item.isFile, (item.fromDevice ?? "Clipboard").caseInsensitiveCompare("Clipboard") == .orderedSame,
              let name = item.filename, let size = item.size else { return false }
        lock.lock(); defer { lock.unlock() }
        return entries.contains { $0.name == name && $0.size == size && now.timeIntervalSince($0.at) <= ttl }
    }
}

// MARK: - Transfer-folder watcher logic

/// Decides which top-level entries of the transfer folder are new and finished, and should be sent.
///
/// * The first time (no index yet, or another folder) everything already there is only recorded, never sent.
/// * Only new *names* are sent; a file that is overwritten in place is not re-sent.
/// * Files SyncHub writes itself (auto-receive, menu downloads) are announced with `ignore(_:)` and never sent.
/// * Hidden files, `._*`, `.DS_Store`, and unfinished downloads (.download, .crdownload, .part, .downloading,
///   .tmp, Office `~$` lock files…) are skipped; a finished download that is renamed to its real name is new.
/// * An entry is sent only when its size + modification time stayed the same for `stableSeconds`
///   (copies that are still being written wait); folders count all their contents and are sent as .zip.
/// Thread-safe (one lock); `ignore` is called from the receiver's queue, `scan` from the main thread.
final class FolderOutbox {
    struct Sig: Codable, Equatable { var size: Int64; var mtime: Double }
    private struct Index: Codable { var dir: String; var known: [String: Sig] }

    let indexURL: URL
    private(set) var dir: URL
    private var known: [String: Sig] = [:]
    private var pending: [String: (sig: Sig, since: Date)] = [:]
    private var ignored: [String: Date] = [:]
    var stableSeconds: TimeInterval = 3
    private let fm: FileManager
    private let lock = NSLock()

    init(dir: URL, indexURL: URL, fm: FileManager = .default) {
        self.dir = dir.standardizedFileURL
        self.indexURL = indexURL
        self.fm = fm
        if let d = try? Data(contentsOf: indexURL), let idx = try? JSONDecoder().decode(Index.self, from: d),
           idx.dir == self.dir.path {
            known = idx.known
        } else {
            baseline()
        }
    }

    /// Forget everything and record what is in `dir` now as already handled (nothing is sent).
    func reset(dir newDir: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let n = newDir { dir = n.standardizedFileURL }
        pending = [:]
        baseline()
    }

    /// A file SyncHub itself is about to create in the folder (receive / download). Call before it appears.
    func ignore(_ url: URL, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard url.deletingLastPathComponent().standardizedFileURL.path == dir.path else { return }
        ignored[url.lastPathComponent] = now
    }

    static let partialSuffixes = [".download", ".crdownload", ".part", ".partial", ".downloading", ".tmp", ".temp",
                                  ".opdownload", ".icloud", ".sb-", ".swp"]

    static func isCandidateName(_ n: String) -> Bool {
        if n.isEmpty || n.hasPrefix(".") || n.hasPrefix("~$") || n.hasPrefix("._") { return false }
        let l = n.lowercased()
        if l == "desktop.ini" || l == "thumbs.db" || l == "icon\r" { return false }
        for s in partialSuffixes where l.hasSuffix(s) { return false }
        if l.contains(".sb-") { return false }               // Safari / sandbox temp names "x.sb-1234-abcd"
        return true
    }

    /// One pass. Returns entries that are ready to send (and from now on counted as known).
    func scan(now: Date = Date()) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let present = Set(names)
        var changed = false
        // Deleted entries are forgotten, so putting a file with the same name back later sends it again.
        for k in Array(known.keys) where !present.contains(k) { known.removeValue(forKey: k); changed = true }
        for k in Array(pending.keys) where !present.contains(k) { pending.removeValue(forKey: k) }
        for (k, t) in ignored where now.timeIntervalSince(t) > 600 && !present.contains(k) { ignored.removeValue(forKey: k) }

        var ready: [URL] = []
        for n in names.sorted() where known[n] == nil {
            let u = dir.appendingPathComponent(n)
            guard let sig = signature(u) else { continue }
            if ignored.removeValue(forKey: n) != nil || !FolderOutbox.isCandidateName(n) {
                if FolderOutbox.isCandidateName(n) { known[n] = sig; changed = true }
                continue
            }
            if let p = pending[n], p.sig == sig {
                if now.timeIntervalSince(p.since) >= stableSeconds && now.timeIntervalSince1970 - sig.mtime >= stableSeconds {
                    pending.removeValue(forKey: n)
                    known[n] = sig; changed = true
                    ready.append(u)
                }
            } else {
                pending[n] = (sig, now)
            }
        }
        if changed { save() }
        return ready
    }

    /// For tests / diagnostics.
    var knownNames: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(known.keys) }

    private func baseline() {
        known = [:]
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for n in names where FolderOutbox.isCandidateName(n) {
                if let s = signature(dir.appendingPathComponent(n)) { known[n] = s }
            }
        }
        save()
    }

    private func save() {
        try? fm.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Index(dir: dir.path, known: known)) { try? d.write(to: indexURL, options: .atomic) }
    }

    /// Size + newest mtime; for folders the sum / max over everything inside (capped at 20 000 entries).
    func signature(_ u: URL) -> Sig? {
        guard let a = try? fm.attributesOfItem(atPath: u.path) else { return nil }
        var size = (a[.size] as? NSNumber)?.int64Value ?? 0
        var mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if (a[.type] as? FileAttributeType) == .typeDirectory, let e = fm.enumerator(atPath: u.path) {
            size = 0
            var n = 0
            while let rel = e.nextObject() as? String, n < 20_000 {
                n += 1
                if let fa = try? fm.attributesOfItem(atPath: u.appendingPathComponent(rel).path) {
                    size += (fa[.size] as? NSNumber)?.int64Value ?? 0
                    mtime = max(mtime, (fa[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
                }
            }
        }
        return Sig(size: size, mtime: mtime)
    }
}

// MARK: - Files copied in Finder

enum ClipFilePlan: Equatable {
    /// One regular file within the limit: goes onto the shared clipboard (SyncClipboard "File"), so Windows can paste it.
    case clipboard(URL, size: Int64)
    /// Several files, or a folder, within the limit: sent through SyncHub (lands in the other devices' transfer folders).
    case upload([URL], total: Int64)
    case tooLarge(total: Int64)
    case none

    static func make(_ urls: [URL], maxBytes: Int64, fm: FileManager = .default) -> ClipFilePlan {
        let files = urls.filter { $0.isFileURL && fm.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return .none }
        var total: Int64 = 0
        var anyDir = false
        for u in files {
            var d: ObjCBool = false
            _ = fm.fileExists(atPath: u.path, isDirectory: &d)
            if d.boolValue {
                anyDir = true
                guard let e = fm.enumerator(atPath: u.path) else { continue }
                var n = 0
                while let rel = e.nextObject() as? String {
                    n += 1
                    total += ((try? fm.attributesOfItem(atPath: u.appendingPathComponent(rel).path))?[.size] as? NSNumber)?.int64Value ?? 0
                    if total > maxBytes || n > 20_000 { return .tooLarge(total: total) }
                }
            } else {
                total += ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
            }
            if total > maxBytes { return .tooLarge(total: total) }
        }
        if files.count == 1 && !anyDir { return .clipboard(files[0], size: total) }
        return .upload(files, total: total)
    }

    /// Same selection copied again (⌘C twice) → same signature → not sent twice.
    static func signature(_ urls: [URL], fm: FileManager = .default) -> String {
        urls.map { u -> String in
            let a = try? fm.attributesOfItem(atPath: u.path)
            let s = (a?[.size] as? NSNumber)?.int64Value ?? -1
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(u.path)|\(s)|\(Int64(m * 1000))"
        }.joined(separator: "\n")
    }
}
