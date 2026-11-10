// HubCore.swift — Foundation-only SyncHub API client + auto-receiver.
// No AppKit here, so this file also compiles/tests on Linux (FoundationNetworking).
// It speaks exactly the existing SyncHub HTTP API; the server is NOT modified.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models (mirror enrich_row() in synchub_server.py)

struct HubItem: Decodable, Equatable {
    let id: Int
    let type: Int                 // 0 Text, 1 File, 2 Image, 3 Group
    let typeName: String?
    let text: String?
    let filename: String?
    let size: Int64?
    let createTimeUtc: String?
    let createTimeLocal: String?
    let starred: Bool?
    let pinned: Bool?
    let isPermanent: Bool?
    let remainingSeconds: Int?
    let fromDevice: String?
    let category: String?
    let hasFile: Bool?
    let downloadUrl: String?

    var isFile: Bool { type == 1 || type == 2 }

    /// Name shown in the menu: file name for files, first line of text otherwise.
    var displayName: String {
        if isFile, let f = filename, !f.isEmpty { return f }
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let first = t.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        return first.isEmpty ? "(空)" : first
    }

    var createdAt: Date? {
        guard let s = createTimeUtc else { return nil }
        return HubFormat.isoParser.date(from: s)
    }
}

extension Array where Element == HubItem {
    /// Same order as the SyncHub web UI / Android: pinned first, then starred, then newest (higher id) first.
    func hubOrdered() -> [HubItem] {
        sorted { a, b in
            let ap = a.pinned == true, bp = b.pinned == true
            if ap != bp { return ap }
            let ast = a.starred == true, bst = b.starred == true
            if ast != bst { return ast }
            return a.id > b.id
        }
    }
}

/// GET /api/hub/storage — disk of the server's data directory (+ how much of it SyncHub itself uses).
struct HubStorage: Decodable, Equatable {
    let total: Int64
    let used: Int64
    let free: Int64
    let hubBytes: Int64?

    var usedFraction: Double { total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0 }

    /// 1024-based, same as the web UI / Android ("10.6 GB"); ≥ 100 shown without decimals.
    static func fmt(_ b: Int64) -> String {
        let v = Double(max(0, b))
        let k = 1024.0
        let units: [(Double, String)] = [(k * k * k * k, "TB"), (k * k * k, "GB"), (k * k, "MB"), (k, "KB")]
        for (u, name) in units where v >= u {
            let x = v / u
            return x >= 100 ? "\(Int(x.rounded())) \(name)" : String(format: "%.1f %@", x, name)
        }
        return "\(Int(v)) B"
    }

    /// Menu line: "存储 已用 10.6 GB / 58.9 GB · 剩余 45.3 GB"
    var menuLine: String { "存储 已用 \(HubStorage.fmt(used)) / \(HubStorage.fmt(total)) · 剩余 \(HubStorage.fmt(free))" }
}
private struct HubStorageResponse: Decodable {
    let ok: Bool?; let total: Int64?; let used: Int64?; let free: Int64?; let hubBytes: Int64?
    let storage: HubStorage?
}

struct HubItemsResponse: Decodable { let ok: Bool?; let items: [HubItem]?; let retentionHours: Int? }
struct HubAutoPullResponse: Decodable { let ok: Bool?; let latestId: Int?; let items: [HubItem]? }
struct HubItemResponse: Decodable { let ok: Bool?; let item: HubItem?; let error: String? }

// MARK: - Errors

enum HubError: Error, LocalizedError {
    case notConfigured
    case badURL(String)
    case http(Int, String)
    case network(String)
    case decoding(String)
    case cancelled
    case local(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未设置服务器地址"
        case .badURL(let s): return "服务器地址无效：\(s)"
        case .http(let code, let body):
            switch code {
            case 401, 403: return "用户名或密码不正确 (HTTP \(code))"
            case 404: return "接口不存在或文件已被清理 (HTTP 404)"
            case 413: return "文件超过服务器上限 1 GB (HTTP 413)"
            case 502, 503, 504: return "服务器暂时不可用 (HTTP \(code))"
            default:
                let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return "服务器返回错误 HTTP \(code)" + (b.isEmpty ? "" : "：\(b.prefix(80))")
            }
        case .network(let m): return "网络错误：\(m)"
        case .decoding(let m): return "无法解析服务器响应：\(m)"
        case .cancelled: return "已取消"
        case .local(let m): return m
        }
    }

    var isCancelled: Bool { if case .cancelled = self { return true }; return false }
}

// MARK: - Config

struct HubConfig: Equatable {
    var baseURL: String          // e.g. https://020814.xyz (no trailing slash needed)
    var username: String = ""    // optional HTTP Basic auth (sent only if non-empty)
    var password: String = ""
    var device: String = "Mac"   // "from" on upload; lowercased for auto-pull ?device=

    var normalizedBase: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty && !s.contains("://") { s = "https://" + s }
        return s
    }
    var webURL: URL? { URL(string: normalizedBase + "/hub/") }
}

// MARK: - Formatting helpers

enum HubFormat {
    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Same rules as format_bytes() in the Windows client.
    static func bytes(_ b: Int64) -> String {
        if b <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(b); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i > 1 ? String(format: "%.2f %@", v, units[i]) : "\(Int(v)) \(units[i])"
    }

    static func relative(_ d: Date?, now: Date = Date()) -> String {
        guard let d = d else { return "" }
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    /// "剩 5 小时" style countdown for non-permanent items (72h retention on server).
    static func remaining(_ secs: Int?) -> String? {
        guard let s = secs else { return nil }
        if s <= 0 { return "即将清理" }
        if s < 3600 { return "剩 \(max(1, s / 60)) 分钟" }
        if s < 86400 { return "剩 \(s / 3600) 小时" }
        return "剩 \(s / 86400) 天"
    }

    /// Percent-encode a query value strictly (RFC 3986 unreserved only), so '+', '&', '=' survive parse_qs.
    static func queryEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // alphanumerics includes non-ASCII letters; restrict to ASCII.
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed.intersection(ascii)) ?? s
    }

    /// Strip path separators / control chars so a server-provided name can't escape the receive folder.
    static func safeFilename(_ name: String, fallback: String) -> String {
        var n = (name as NSString).lastPathComponent
        n = n.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        n = String(n.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(Character.init))
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == "." || n == ".." { return fallback }
        return n
    }

    /// True if "name.ext" or any existing "name (n).ext" already has exactly `size` bytes (no re-download).
    static func alreadyHave(in dir: URL, filename: String, size: Int64, fm: FileManager = .default) -> Bool {
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        var i = 0
        while i < 1000 {
            let n = i == 0 ? filename : (ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            let p = dir.appendingPathComponent(n).path
            guard fm.fileExists(atPath: p) else { return false }
            if ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value == size { return true }
            i += 1
        }
        return false
    }

    /// "name.ext" -> "name (1).ext", "name (2).ext", ... (same as get_unique_dest_path on Windows)
    static func uniqueURL(in dir: URL, filename: String, fm: FileManager = .default) -> URL {
        let first = dir.appendingPathComponent(filename)
        if !fm.fileExists(atPath: first.path) { return first }
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        var i = 1
        while true {
            let cand = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            if !fm.fileExists(atPath: cand.path) { return cand }
            i += 1
        }
    }
}

// MARK: - Upload handle

final class HubUploadHandle {
    fileprivate weak var task: URLSessionTask?
    fileprivate var cancelled = false
    func cancel() { cancelled = true; task?.cancel() }
}

// MARK: - Client

final class HubClient: NSObject, URLSessionDataDelegate {
    let config: HubConfig

    private struct UploadCallbacks {
        let progress: (Int64, Int64) -> Void
        let completion: (Result<HubItem?, HubError>) -> Void
        var body = Data()
        let handle: HubUploadHandle
    }
    private var uploads: [Int: UploadCallbacks] = [:]
    private let lock = NSLock()
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.name = "synchub.client"; return q
    }()

    /// Short requests (list, auto-pull, text): 20 s.
    private lazy var apiSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "SyncHub-Mac/1.1.1"]
        return URLSession(configuration: c)
    }()
    /// Large transfers: long resource timeout (server allows up to 1 GB, nginx read timeout 3600 s).
    private lazy var transferSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 4 * 3600
        c.httpAdditionalHeaders = ["User-Agent": "SyncHub-Mac/1.1.1"]
        return URLSession(configuration: c, delegate: self, delegateQueue: delegateQueue)
    }()

    init(config: HubConfig) { self.config = config; super.init() }

    /// Drop this client (settings changed). Running uploads are allowed to finish.
    func invalidate() {
        apiSession.invalidateAndCancel()
        transferSession.finishTasksAndInvalidate()
    }

    // MARK: request building

    func url(_ path: String, query: [(String, String)] = []) throws -> URL {
        let base = config.normalizedBase
        guard !base.isEmpty else { throw HubError.notConfigured }
        var s = base + path
        if !query.isEmpty {
            s += "?" + query.map { "\($0.0)=\(HubFormat.queryEscape($0.1))" }.joined(separator: "&")
        }
        guard let u = URL(string: s), u.host != nil else { throw HubError.badURL(base) }
        return u
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if !config.username.isEmpty {
            let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private static func check(_ data: Data?, _ resp: URLResponse?, _ err: Error?) -> Result<Data, HubError> {
        if let e = err as NSError? {
            if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return .failure(.cancelled) }
            return .failure(.network(e.localizedDescription))
        }
        guard let http = resp as? HTTPURLResponse else { return .failure(.network("无响应")) }
        let body = data ?? Data()
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.http(http.statusCode, String(decoding: body.prefix(300), as: UTF8.self)))
        }
        return .success(body)
    }

    private func getJSON<T: Decodable>(_ req: URLRequest, _ type: T.Type, completion: @escaping (Result<T, HubError>) -> Void) {
        apiSession.dataTask(with: req) { data, resp, err in
            switch HubClient.check(data, resp, err) {
            case .failure(let e): completion(.failure(e))
            case .success(let body):
                do { completion(.success(try JSONDecoder().decode(T.self, from: body))) }
                catch { completion(.failure(.decoding(String(describing: error).prefix(120).description))) }
            }
        }.resume()
    }

    // MARK: API

    /// GET /api/hub/items?limit=N  (pinned, then starred, then newest — re-sorted here so older servers match too)
    func listItems(limit: Int = 15, completion: @escaping (Result<[HubItem], HubError>) -> Void) {
        do {
            let req = request(try url("/api/hub/items", query: [("limit", String(limit))]))
            getJSON(req, HubItemsResponse.self) { r in completion(r.map { ($0.items ?? []).hubOrdered() }) }
        } catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }

    /// GET /api/hub/storage  {"total","used","free","hubBytes"} (flat, or nested under "storage")
    func storage(completion: @escaping (Result<HubStorage, HubError>) -> Void) {
        do {
            let req = request(try url("/api/hub/storage"))
            getJSON(req, HubStorageResponse.self) { r in
                completion(r.flatMap { s in
                    if let n = s.storage { return .success(n) }
                    guard let t = s.total, let u = s.used else { return .failure(.decoding("缺少 total/used")) }
                    return .success(HubStorage(total: t, used: u, free: s.free ?? max(0, t - u), hubBytes: s.hubBytes))
                })
            }
        } catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }

    /// GET /api/hub/auto-pull?device=mac&since_id=N  (same call as the old LaunchAgent / Windows daemon)
    func autoPull(sinceId: Int, completion: @escaping (Result<HubAutoPullResponse, HubError>) -> Void) {
        do {
            let req = request(try url("/api/hub/auto-pull",
                                      query: [("device", config.device.lowercased()), ("since_id", String(sinceId))]))
            getJSON(req, HubAutoPullResponse.self, completion: completion)
        } catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }

    /// POST /api/hub/text  {"text","from","syncClipboard":true}
    func postText(_ text: String, syncClipboard: Bool = true, completion: @escaping (Result<HubItem?, HubError>) -> Void) {
        do {
            var req = request(try url("/api/hub/text"), method: "POST")
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["text": text, "from": config.device, "syncClipboard": syncClipboard]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            getJSON(req, HubItemResponse.self) { r in completion(r.map { $0.item }) }
        } catch { completion(.failure(error as? HubError ?? .local("\(error)"))) }
    }

    /// POST /api/hub/upload?filename=..&from=Mac — raw body streamed from disk (no RAM copy).
    /// The server runs parse_qs() AND urllib.parse.unquote() on `filename`, so we percent-encode twice;
    /// that round-trips every name exactly (incl. '%', '+', '&', '#', Chinese, emoji).
    @discardableResult
    func upload(fileURL: URL, filename: String? = nil, starred: Bool = false, pinned: Bool = false,
                progress: @escaping (Int64, Int64) -> Void,
                completion: @escaping (Result<HubItem?, HubError>) -> Void) -> HubUploadHandle {
        let handle = HubUploadHandle()
        let name = filename ?? fileURL.lastPathComponent
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let u = try url("/api/hub/upload", query: [
                ("filename", HubFormat.queryEscape(name)),
                ("from", config.device),
                ("starred", starred ? "1" : "0"),
                ("pinned", pinned ? "1" : "0"),
            ])
            var req = request(u, method: "POST")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Server reads exactly Content-Length bytes; never let this become chunked.
            req.setValue(String(size), forHTTPHeaderField: "Content-Length")
            let task = transferSession.uploadTask(with: req, fromFile: fileURL)
            handle.task = task
            lock.lock()
            uploads[task.taskIdentifier] = UploadCallbacks(progress: progress, completion: completion, handle: handle)
            lock.unlock()
            task.resume()
        } catch {
            completion(.failure(error as? HubError ?? .local("无法读取文件：\(error.localizedDescription)")))
        }
        return handle
    }

    /// GET <downloadUrl> into a temp file; caller moves it. Returns the task for cancellation.
    @discardableResult
    func download(item: HubItem, completion: @escaping (Result<URL, HubError>) -> Void) -> URLSessionTask? {
        guard let path = item.downloadUrl, let u = URL(string: config.normalizedBase + path) else {
            completion(.failure(.local("该条目没有可下载的文件"))); return nil
        }
        let req = request(u)
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 120; c.timeoutIntervalForResource = 4 * 3600
            c.httpAdditionalHeaders = ["User-Agent": "SyncHub-Mac/1.1.1"]
            return c
        }())
        let task = session.downloadTask(with: req) { tmp, resp, err in
            defer { session.finishTasksAndInvalidate() }
            switch HubClient.check(Data(), resp, err) {
            case .failure(let e): completion(.failure(e))
            case .success:
                guard let tmp = tmp else { completion(.failure(.network("下载为空"))); return }
                // The temp file is deleted when this handler returns, so move it now.
                let keep = FileManager.default.temporaryDirectory
                    .appendingPathComponent("synchub-\(UUID().uuidString).download")
                do { try FileManager.default.moveItem(at: tmp, to: keep); completion(.success(keep)) }
                catch { completion(.failure(.local("保存下载失败：\(error.localizedDescription)"))) }
            }
        }
        task.resume()
        return task
    }

    // MARK: URLSession delegate (upload progress + body collection)

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let cb = uploads[task.taskIdentifier]; lock.unlock()
        cb?.progress(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); uploads[dataTask.taskIdentifier]?.body.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let cb = uploads.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let cb = cb else { return }
        if cb.handle.cancelled { cb.completion(.failure(.cancelled)); return }
        switch HubClient.check(cb.body, task.response, error) {
        case .failure(let e): cb.completion(.failure(e))
        case .success(let body):
            let r = try? JSONDecoder().decode(HubItemResponse.self, from: body)
            if r?.ok == false { cb.completion(.failure(.local(r?.error ?? "服务器拒绝了上传"))) }
            else { cb.completion(.success(r?.item)) }
        }
    }
}

// MARK: - Auto receiver (same logic as the Windows daemon / old macOS LaunchAgent)
//
// * remembers the last seen record id; first run only records the current max id (no history flood)
// * asks the server for new File/Image records not sent by this device
// * skips a file that already exists with the same size; otherwise saves "name (1).ext"
// * writes to "<name>.downloading" first, then renames, so half files never appear
// * if a download fails, last_id stops just before that item so it is retried next poll

final class HubAutoReceiver {
    let stateURL: URL
    var clientProvider: () -> HubClient?
    var directoryProvider: () -> URL
    /// Called (on a background queue) for every file saved.
    var onReceived: ((HubItem, URL) -> Void)?
    /// Called after each poll: success(count of saved files) or failure.
    var onPoll: ((Result<Int, HubError>) -> Void)?

    private let queue = DispatchQueue(label: "synchub.receiver")
    private var busy = false
    /// Consecutive non-network failures per item id; after 3 the item is skipped so one bad file
    /// (disk error, server 5xx on that file…) can't block every later file forever. Same as Android.
    private var failures: [Int: Int] = [:]
    private let fm = FileManager.default

    init(stateURL: URL, legacyStateURL: URL? = nil,
         clientProvider: @escaping () -> HubClient?, directoryProvider: @escaping () -> URL) {
        self.stateURL = stateURL
        self.clientProvider = clientProvider
        self.directoryProvider = directoryProvider
        // Migrate ~/.synchub/last_id.txt from the old LaunchAgent so we don't re-download anything.
        if !fm.fileExists(atPath: stateURL.path), let legacy = legacyStateURL,
           let s = try? String(contentsOf: legacy, encoding: .utf8),
           let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0 {
            lastId = v
        }
    }

    var lastId: Int {
        get {
            guard let d = try? Data(contentsOf: stateURL),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
            return (o["last_id"] as? NSNumber)?.intValue ?? 0
        }
        set {
            try? fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let o: [String: Any] = ["last_id": newValue, "updated_at": Date().timeIntervalSince1970]
            if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: stateURL, options: .atomic) }
        }
    }

    /// One poll. Safe to call from a timer: overlapping calls are ignored while a poll is running.
    func pollOnce(done: (() -> Void)? = nil) {
        queue.async {
            guard !self.busy, let client = self.clientProvider() else { done?(); return }
            self.busy = true
            let since = self.lastId
            client.autoPull(sinceId: since) { result in
                self.queue.async {
                    switch result {
                    case .failure(let e):
                        self.finish(.failure(e), done)
                    case .success(let resp):
                        guard resp.ok != false else { self.finish(.success(0), done); return }
                        let latest = max(since, resp.latestId ?? since)
                        if since <= 0 {               // first run: just remember where we are
                            self.lastId = latest
                            self.finish(.success(0), done); return
                        }
                        self.process(items: resp.items ?? [], client: client, latest: latest, saved: 0, done: done)
                    }
                }
            }
        }
    }

    private func finish(_ r: Result<Int, HubError>, _ done: (() -> Void)?) {
        busy = false
        onPoll?(r)
        done?()
    }

    private func process(items: [HubItem], client: HubClient, latest: Int, saved: Int, done: (() -> Void)?) {
        guard let item = items.first else {
            if latest > lastId { lastId = latest }
            finish(.success(saved), done); return
        }
        let rest = Array(items.dropFirst())
        guard item.downloadUrl != nil else {
            process(items: rest, client: client, latest: latest, saved: saved, done: done); return
        }
        let dir = directoryProvider()
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { failAt(item, .local("无法创建接收文件夹：\(error.localizedDescription)"), done); return }

        let name = HubFormat.safeFilename(item.filename ?? "", fallback: "file_\(item.id)")
        let expected = item.size ?? 0
        if expected > 0 && HubFormat.alreadyHave(in: dir, filename: name, size: expected, fm: fm) {
            process(items: rest, client: client, latest: latest, saved: saved, done: done); return
        }
        let finalDest = HubFormat.uniqueURL(in: dir, filename: name, fm: fm)
        client.download(item: item) { r in
            self.queue.async {
                switch r {
                case .failure(.http(404, _)):   // purged/deleted on the server meanwhile: skip, don't loop forever
                    self.lastId = max(self.lastId, item.id)
                    self.process(items: rest, client: client, latest: latest, saved: saved, done: done)
                case .failure(let e):
                    self.failAt(item, e, done)
                case .success(let tmp):
                    let part = finalDest.appendingPathExtension("downloading")
                    do {
                        try? self.fm.removeItem(at: part)
                        try self.fm.moveItem(at: tmp, to: part)
                        try self.fm.moveItem(at: part, to: finalDest)
                    } catch {
                        try? self.fm.removeItem(at: tmp)
                        self.failAt(item, .local("保存文件失败：\(error.localizedDescription)"), done); return
                    }
                    self.lastId = max(self.lastId, item.id)
                    self.failures.removeValue(forKey: item.id)
                    self.onReceived?(item, finalDest)
                    self.process(items: rest, client: client, latest: latest, saved: saved + 1, done: done)
                }
            }
        }
    }

    private func failAt(_ item: HubItem, _ e: HubError, _ done: (() -> Void)?) {
        var permanent = false
        switch e {
        case .http, .local: permanent = true
        default: break                       // network / cancelled: transient, retry without counting
        }
        let n = permanent ? (failures[item.id] ?? 0) + 1 : (failures[item.id] ?? 0)
        if n >= 3 {
            // Give up on this item so later files still arrive.
            failures.removeValue(forKey: item.id)
            if item.id > lastId { lastId = item.id }
        } else {
            if permanent { failures[item.id] = n }
            // Everything before this item is handled; retry this one next poll.
            if item.id - 1 > lastId { lastId = item.id - 1 }
        }
        finish(.failure(e), done)
    }
}
