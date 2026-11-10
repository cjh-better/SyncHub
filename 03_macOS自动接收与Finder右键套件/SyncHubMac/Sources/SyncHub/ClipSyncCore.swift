// ClipSyncCore.swift — Foundation-only clipboard sync logic (SyncClipboard v3 protocol).
// No AppKit here, so it compiles and is tested on Linux (Tests/LinuxHarness). The pasteboard glue
// (NSPasteboard polling / writing) lives in ClipboardSync.swift.
//
// Protocol — identical to the Android app (net/SyncClipboardClient.kt) and the official SyncClipboard clients:
//   GET  {base}/SyncClipboard.json            GET {base}/file/{dataName}
//   PUT  {base}/SyncClipboard.json (JSON)     PUT {base}/file/{dataName} (raw bytes)
//   JSON keys (camelCase, written by the official server): type, hash, text, hasData, dataName, transferDataHash, size.
//   SyncHub's /api/hub/text writes the same file in PascalCase (Type, Hash, Text…), so parsing accepts both.
//   Text hash  = uppercase hex SHA-256 of the UTF-8 text.
//   Image hash = SHA-256(UTF-8 "fileName|CONTENTHASH"), CONTENTHASH = uppercase SHA-256 of the bytes.
//   Text longer than 10240 characters is uploaded as Text_*.txt with hasData=true (same as official client/Android).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - SHA-256 (pure Swift, so Linux and every macOS version behave the same)

enum ClipHash {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    static func sha256(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var chunk = 0
        while chunk < msg.count {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            chunk += 64
        }
        var out = [UInt8](); out.reserveCapacity(32)
        for v in h { out += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        return out
    }

    /// Uppercase hex, like Hashing.sha256Hex on Android and the official SyncClipboard clients.
    static func sha256Hex(_ data: Data) -> String {
        let hex = Array("0123456789ABCDEF")
        var s = ""; s.reserveCapacity(64)
        for b in sha256(data) { s.append(hex[Int(b >> 4)]); s.append(hex[Int(b & 0x0f)]) }
        return s
    }

    /// Text profile hash = SHA256(UTF8(text))
    static func text(_ s: String) -> String { sha256Hex(Data(s.utf8)) }

    /// Image / file profile hash = SHA256(UTF8("fileName|CONTENTHASH"))
    static func fileProfile(name: String, contentHash: String) -> String {
        sha256Hex(Data("\(name)|\(contentHash.uppercased())".utf8))
    }

    static func short(_ h: String) -> String { String(h.prefix(8)) }
}

// MARK: - SyncClipboard.json

struct ClipProfile: Equatable {
    var type: String              // Text / Image / File / Group
    var hash: String
    var text: String
    var hasData: Bool
    var dataName: String?
    var transferDataHash: String? = nil
    var size: Int64? = nil

    /// Accepts camelCase (official server) and PascalCase (SyncHub /api/hub/text, old versions); v2 Clipboard/File fallback.
    static func parse(_ data: Data) throws -> ClipProfile {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HubError.decoding("SyncClipboard.json 不是有效的 JSON")
        }
        func val(_ name: String) -> Any? {
            for k in [name, name.prefix(1).uppercased() + name.dropFirst()] {
                if let v = o[k], !(v is NSNull) { return v }
            }
            return nil
        }
        func s(_ n: String) -> String? {
            guard let v = val(n) else { return nil }
            if let x = v as? String { return x }
            if let x = v as? NSNumber { return x.stringValue }
            return nil
        }
        func b(_ n: String) -> Bool {
            guard let v = val(n) else { return false }
            if let x = v as? Bool { return x }
            if let x = v as? NSNumber { return x.boolValue }
            if let x = v as? String { return x.lowercased() == "true" }
            return false
        }
        func l(_ n: String) -> Int64? {
            guard let v = val(n) else { return nil }
            if let x = v as? NSNumber { return x.int64Value }
            if let x = v as? String { return Int64(x) }
            return nil
        }
        let type = s("type") ?? "Text"
        let text = s("text") ?? s("clipboard") ?? ""
        var dataName = s("dataName")
        if dataName == nil, let f = s("file"), !f.isEmpty { dataName = f }
        return ClipProfile(type: type, hash: s("hash") ?? "", text: text,
                           hasData: b("hasData") || (dataName != nil && !(dataName ?? "").isEmpty && type != "Text"),
                           dataName: dataName, transferDataHash: s("transferDataHash"), size: l("size"))
    }

    /// Same key set as ClipProfile.toJson() on Android.
    func jsonData() -> Data {
        var o: [String: Any] = ["type": type, "hash": hash, "text": text, "hasData": hasData,
                                "dataName": dataName.map { $0 as Any } ?? NSNull()]
        if let t = transferDataHash { o["transferDataHash"] = t }
        if let s = size { o["size"] = NSNumber(value: s) }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    }

    /// Identity of a remote clipboard state (hash, or a synthetic hash for servers that leave it empty).
    var key: String {
        (hash.isEmpty ? ClipHash.text(type + "|" + text + "|" + (dataName ?? "")) : hash).uppercased()
    }

    var hasDataFile: Bool { hasData && !(dataName ?? "").isEmpty }
}

// MARK: - Transport

protocol ClipTransport: AnyObject {
    func getProfile(_ completion: @escaping (Result<ClipProfile, HubError>) -> Void)
    func putProfile(_ p: ClipProfile, _ completion: @escaping (Result<Void, HubError>) -> Void)
    func getFile(_ name: String, maxBytes: Int64, _ completion: @escaping (Result<Data, HubError>) -> Void)
    func putFile(_ name: String, _ data: Data, _ completion: @escaping (Result<Void, HubError>) -> Void)
}

/// HTTP transport using the same base URL and Basic auth as HubClient.
final class SyncClipboardHTTP: ClipTransport {
    let config: HubConfig
    private let session: URLSession

    init(config: HubConfig) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 120
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "SyncHub-Mac/1.1.1"]
        session = URLSession(configuration: c)
    }

    func invalidate() { session.invalidateAndCancel() }

    /// "/file/" + name, percent-encoded like URLEncoder(...).replace("+", "%20") on Android.
    func fileURL(_ name: String) throws -> URL { try url("/file/" + HubFormat.queryEscape(name)) }

    func url(_ path: String) throws -> URL {
        let base = config.normalizedBase
        guard !base.isEmpty else { throw HubError.notConfigured }
        guard let u = URL(string: base + path), u.host != nil else { throw HubError.badURL(base) }
        return u
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if !config.username.isEmpty {
            let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func run(_ req: URLRequest, maxBytes: Int64 = .max, _ done: @escaping (Result<Data, HubError>) -> Void) {
        session.dataTask(with: req) { data, resp, err in
            if let e = err as NSError? {
                if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { done(.failure(.cancelled)); return }
                done(.failure(.network(e.localizedDescription))); return
            }
            guard let http = resp as? HTTPURLResponse else { done(.failure(.network("无响应"))); return }
            let body = data ?? Data()
            guard (200..<300).contains(http.statusCode) else {
                done(.failure(.http(http.statusCode, String(decoding: body.prefix(200), as: UTF8.self)))); return
            }
            if Int64(body.count) > maxBytes { done(.failure(.local("文件过大（\(HubFormat.bytes(Int64(body.count)))）"))); return }
            done(.success(body))
        }.resume()
    }

    func getProfile(_ completion: @escaping (Result<ClipProfile, HubError>) -> Void) {
        do {
            run(request(try url("/SyncClipboard.json"))) { r in
                switch r {
                case .failure(let e): completion(.failure(e))
                case .success(let d):
                    do { completion(.success(try ClipProfile.parse(d))) }
                    catch { completion(.failure(error as? HubError ?? .decoding("\(error)"))) }
                }
            }
        } catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }

    func putProfile(_ p: ClipProfile, _ completion: @escaping (Result<Void, HubError>) -> Void) {
        do {
            var req = request(try url("/SyncClipboard.json"), method: "PUT")
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = p.jsonData()
            run(req) { completion($0.map { _ in () }) }
        } catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }

    func getFile(_ name: String, maxBytes: Int64, _ completion: @escaping (Result<Data, HubError>) -> Void) {
        do { run(request(try fileURL(name)), maxBytes: maxBytes, completion) }
        catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }

    func putFile(_ name: String, _ data: Data, _ completion: @escaping (Result<Void, HubError>) -> Void) {
        do {
            var req = request(try fileURL(name), method: "PUT")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            run(req) { completion($0.map { _ in () }) }
        } catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }
}

// MARK: - Engine

/// Persisted state, stored per server so switching servers starts from a fresh baseline.
/// * lastRemoteKey: profile key (hash) of the last server state that was handled.
/// * lastRemoteContent: content fingerprint of what the server holds right now, as far as we know
///   (text = SHA-256 of the text, image = "IMG:" + SHA-256 of the bytes; nil = unknown / not a clipboard value).
///   A local copy equal to it is never PUT again. Unlike the in-memory `current`, this survives an engine
///   restart and is shared with a second running copy of the app, so neither can echo a received value back.
protocol ClipStateStore: AnyObject {
    var lastRemoteKey: String? { get set }
    var lastRemoteContent: String? { get set }
}
final class MemoryClipState: ClipStateStore {
    var lastRemoteKey: String?
    var lastRemoteContent: String?
    init(_ k: String? = nil, content: String? = nil) { lastRemoteKey = k; lastRemoteContent = content }
}

enum ClipLocalResult: Equatable {
    case pushed(hash: String)
    case skipped(String)        // reason, in Chinese, for the log / status line
}

enum ClipRemoteChange: Equatable {
    case text(String, hash: String)
    case image(name: String, data: Data, key: String)
}

/// Two-way clipboard sync logic, same rules as ClipSyncEngine.kt on Android:
///
/// * Echo guard: `current` is the key of what the local clipboard holds *and* is already in sync with the server
///   (text = text hash, image = "IMG:" + content hash). A local change equal to `current` is our own write coming
///   back (or something we just pushed) and is skipped; a remote change equal to `current` is our own push coming
///   back and is skipped. Copying an older value again (A→B→A) is still synced, because only the *current* value is
///   compared, not a history.
/// * First poll with no saved state only records the server state as a baseline; it never overwrites the clipboard.
/// * lastRemoteKey only advances once a remote change was handled (written or deliberately skipped); a failed
///   download is retried next poll, and given up after 3 failures so one bad entry can't block sync forever.
/// * While a local push is in flight, remote polls are skipped so an older server value can't overwrite a new copy.
///
/// All state is touched on one serial queue; completions are delivered on that queue.
final class ClipSyncEngine {
    static let textThreshold = 10240                  // chars (UTF-16, like Kotlin String.length)
    let transport: ClipTransport
    let state: ClipStateStore
    var maxTextBytes: Int = 500 * 1024
    var maxImageBytes: Int64 = 20 * 1024 * 1024
    var pullImages: () -> Bool = { true }
    var log: (String) -> Void = { _ in }
    /// For tests: fixed name generator.
    var nameStamp: () -> String = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date()) + "_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    let queue = DispatchQueue(label: "synchub.clipsync")
    private(set) var current: String?
    private var pushing = 0
    private var pushGeneration = 0      // bumped whenever a local push starts; stale poll answers are dropped
    private var polling = false
    private var failKey: String?
    private var failCount = 0

    init(transport: ClipTransport, state: ClipStateStore) {
        self.transport = transport
        self.state = state
    }

    /// Value currently on the local clipboard that is known to be in sync (for tests / diagnostics).
    func currentKey() -> String? { queue.sync { current } }

    /// Undo `current` after a failed local pasteboard write, so a later identical local copy is not mistaken for an echo.
    func release(_ key: String) { queue.async { if self.current == key.uppercased() { self.current = nil } } }

    /// Mark a value as already being on the local clipboard (e.g. the text the app itself wrote from a menu action).
    func noteLocal(textHash: String) { queue.async { self.current = textHash.uppercased() } }

    // MARK: local → server

    func onLocalText(_ text: String, _ completion: @escaping (Result<ClipLocalResult, HubError>) -> Void) {
        queue.async {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completion(.success(.skipped("空白文字"))); return }
            let bytes = Data(text.utf8)
            if bytes.count > self.maxTextBytes {
                self.log("本地文字 \(HubFormat.bytes(Int64(bytes.count))) 超过上限，跳过")
                completion(.success(.skipped("文字超过 \(self.maxTextBytes / 1024) KB，未同步"))); return
            }
            let hash = ClipHash.sha256Hex(bytes)
            if self.current == hash {
                self.log("本地文字 #\(ClipHash.short(hash)) 与当前已同步内容相同，跳过")
                completion(.success(.skipped("与已同步内容相同"))); return
            }
            if self.state.lastRemoteContent?.uppercased() == hash {
                // The server already holds exactly this text (typically: we just received it) — never echo it back.
                self.current = hash
                self.log("本地文字 #\(ClipHash.short(hash)) 与服务器当前内容相同（刚收到的），不回传")
                completion(.success(.skipped("与服务器内容相同"))); return
            }
            self.current = hash
            self.pushing += 1; self.pushGeneration += 1
            let finish: (Result<Void, HubError>) -> Void = { r in
                self.queue.async {
                    self.pushing -= 1
                    switch r {
                    case .success:
                        self.state.lastRemoteKey = hash
                        self.state.lastRemoteContent = hash
                        self.log("已推送文字 \(text.utf16.count) 字 #\(ClipHash.short(hash))")
                        completion(.success(.pushed(hash: hash)))
                    case .failure(let e):
                        if self.current == hash { self.current = nil }
                        completion(.failure(e))
                    }
                }
            }
            let chars = text.utf16.count
            if chars > ClipSyncEngine.textThreshold {
                let name = "Text_\(self.nameStamp()).txt"
                let prefix = String(decoding: Array(text.utf16.prefix(ClipSyncEngine.textThreshold)), as: UTF16.self)
                let p = ClipProfile(type: "Text", hash: hash, text: prefix, hasData: true, dataName: name,
                                    transferDataHash: hash, size: Int64(chars))
                self.transport.putFile(name, bytes) { r in
                    switch r {
                    case .failure(let e): finish(.failure(e))
                    case .success: self.transport.putProfile(p, finish)
                    }
                }
            } else {
                let p = ClipProfile(type: "Text", hash: hash, text: text, hasData: false, dataName: nil, size: Int64(chars))
                self.transport.putProfile(p, finish)
            }
        }
    }

    func onLocalImage(name: String, data: Data, _ completion: @escaping (Result<ClipLocalResult, HubError>) -> Void) {
        queue.async {
            if Int64(data.count) > self.maxImageBytes {
                completion(.success(.skipped("图片超过 \(HubFormat.bytes(self.maxImageBytes))，未同步"))); return
            }
            let content = ClipHash.sha256Hex(data)
            let ckey = "IMG:" + content
            if self.current == ckey { completion(.success(.skipped("与已同步图片相同"))); return }
            if self.state.lastRemoteContent?.uppercased() == ckey.uppercased() {
                self.current = ckey
                self.log("本地图片与服务器当前图片相同（刚收到的），不回传")
                completion(.success(.skipped("与服务器图片相同"))); return
            }
            self.current = ckey
            self.pushing += 1; self.pushGeneration += 1
            let hash = ClipHash.fileProfile(name: name, contentHash: content)
            let p = ClipProfile(type: "Image", hash: hash, text: name, hasData: true, dataName: name,
                                transferDataHash: content, size: Int64(data.count))
            self.transport.putFile(name, data) { r in
                let done: (Result<Void, HubError>) -> Void = { r in
                    self.queue.async {
                        self.pushing -= 1
                        switch r {
                        case .success:
                            self.state.lastRemoteKey = hash
                            self.state.lastRemoteContent = ckey
                            self.log("已推送图片 \(name)（\(HubFormat.bytes(Int64(data.count)))）")
                            completion(.success(.pushed(hash: hash)))
                        case .failure(let e):
                            if self.current == ckey { self.current = nil }
                            completion(.failure(e))
                        }
                    }
                }
                switch r {
                case .failure(let e): done(.failure(e))
                case .success: self.transport.putProfile(p, done)
                }
            }
        }
    }

    // MARK: server → local

    /// One poll. Returns nil when there is nothing to write to the local clipboard.
    func pollRemote(_ completion: @escaping (Result<ClipRemoteChange?, HubError>) -> Void) {
        queue.async {
            if self.polling || self.pushing > 0 { completion(.success(nil)); return }
            self.polling = true
            let gen = self.pushGeneration
            let done: (Result<ClipRemoteChange?, HubError>) -> Void = { r in self.polling = false; completion(r) }
            self.transport.getProfile { r in
                self.queue.async {
                    switch r {
                    case .failure(let e): done(.failure(e))
                    case .success(let p):
                        // A local copy was pushed while this GET was in flight: the answer may be older than it.
                        if gen != self.pushGeneration { done(.success(nil)); return }
                        self.handle(p, gen, done)
                    }
                }
            }
        }
    }

    private func handle(_ p: ClipProfile, _ gen: Int, _ done: @escaping (Result<ClipRemoteChange?, HubError>) -> Void) {
        let key = p.key
        guard let last = state.lastRemoteKey else {
            state.lastRemoteKey = key
            state.lastRemoteContent = (p.type == "Text" && !p.hasDataFile && !p.text.isEmpty) ? ClipHash.text(p.text) : nil
            log("首次同步：记录远端 \(p.type) #\(ClipHash.short(key)) 作为起点，不覆盖本机剪贴板")
            done(.success(nil)); return
        }
        if key == last.uppercased() { done(.success(nil)); return }
        if pushing > 0 { done(.success(nil)); return }      // a local copy started meanwhile; it wins

        // content = fingerprint of what the server now holds (nil if unknown / not a clipboard value)
        let settle: (ClipRemoteChange?, String?) -> Void = { ch, content in
            self.state.lastRemoteKey = key
            self.state.lastRemoteContent = content
            self.failKey = nil; self.failCount = 0
            done(.success(ch))
        }
        let fail: (HubError) -> Void = { e in
            if case .network = e {} else {
                if self.failKey == key { self.failCount += 1 } else { self.failKey = key; self.failCount = 1 }
                if self.failCount >= 3 {
                    self.log("远端 #\(ClipHash.short(key)) 连续 3 次失败，放弃这一条")
                    self.state.lastRemoteKey = key; self.state.lastRemoteContent = nil
                    self.failKey = nil; self.failCount = 0
                }
            }
            done(.failure(e))
        }

        switch p.type {
        case "Text":
            let useText: (String) -> Void = { full in
                if gen != self.pushGeneration { done(.success(nil)); return }
                if full.isEmpty { self.log("远端文字为空，跳过"); settle(nil, nil); return }
                let h = ClipHash.text(full)
                if Data(full.utf8).count > self.maxTextBytes { self.log("远端文字超过上限，跳过"); settle(nil, h); return }
                if self.current == h { self.log("远端文字 #\(ClipHash.short(h)) 与本机相同（自己刚推送的），跳过"); settle(nil, h); return }
                self.current = h
                settle(.text(full, hash: h), h)
            }
            if p.hasDataFile, let name = p.dataName {
                if let sz = p.size, sz > Int64(maxTextBytes) { log("远端长文字超过上限，跳过"); settle(nil, nil); return }
                transport.getFile(name, maxBytes: Int64(maxTextBytes)) { r in
                    self.queue.async {
                        switch r {
                        case .failure(.http(404, _)): self.log("远端长文字文件已不存在，改用摘要"); useText(p.text)
                        case .failure(let e): fail(e)
                        case .success(let d): useText(String(decoding: d, as: UTF8.self))
                        }
                    }
                }
            } else {
                useText(p.text)
            }
        case "Image":
            guard pullImages() else { log("远端图片：已关闭图片同步，跳过"); settle(nil, nil); return }
            guard p.hasDataFile, let name = p.dataName else { log("远端图片没有 dataName，跳过"); settle(nil, nil); return }
            if let sz = p.size, sz > maxImageBytes { log("远端图片过大，跳过"); settle(nil, nil); return }
            transport.getFile(name, maxBytes: maxImageBytes) { r in
                self.queue.async {
                    switch r {
                    case .failure(let e): fail(e)
                    case .success(let d):
                        if gen != self.pushGeneration { done(.success(nil)); return }
                        let ckey = "IMG:" + ClipHash.sha256Hex(d)
                        if self.current == ckey { settle(nil, ckey); return }
                        self.current = ckey
                        settle(.image(name: name, data: d, key: ckey), ckey)
                    }
                }
            }
        default:
            // File / Group: SyncHub's auto-receive already handles files; the clipboard is left alone.
            log("远端 \(p.type)：交给自动接收，剪贴板跳过")
            settle(nil, nil)
        }
    }
}

// MARK: - Pasteboard type rules (pure, testable)

enum ClipPasteboardRules {
    /// nspasteboard.org markers + common password-manager markers: never sync these.
    static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
    ]

    static func isPrivate(_ types: [String]) -> Bool { types.contains { privateTypes.contains($0) } }
}

// MARK: - Backoff

/// 2 s → 4 → 8 → 16 → 30 s cap while the server is unreachable; back to the normal interval after a success.
struct ClipBackoff {
    var base: Double
    var cap: Double = 30
    private(set) var failures = 0
    init(base: Double) { self.base = base }
    mutating func success() { failures = 0 }
    mutating func failure() { failures = min(failures + 1, 10) }
    var delay: Double { failures == 0 ? base : min(cap, max(base, 2) * pow(2, Double(failures - 1))) }
}
