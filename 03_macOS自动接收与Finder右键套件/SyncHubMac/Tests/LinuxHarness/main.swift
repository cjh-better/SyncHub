// Linux test harness for HubCore.swift (run against a LOCAL synchub_server.py only).
// Build: swiftc ../../Sources/SyncHub/HubCore.swift main.swift -o harness
// Run:   ./harness http://127.0.0.1:PORT /tmp/workdir [USER PASS]   (server requires Basic auth since 2026-11-10)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let args = CommandLine.arguments
let base = args[1]; let work = URL(fileURLWithPath: args[2])
let fm = FileManager.default
try? fm.removeItem(at: work); try! fm.createDirectory(at: work, withIntermediateDirectories: true)
var fails = 0
func check(_ label: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + label); if !ok { fails += 1 } }
func wait<T>(_ f: (@escaping (T) -> Void) -> Void) -> T {
    let sem = DispatchSemaphore(value: 0); var out: T!
    f { out = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 60); return out
}
func makeFile(_ name: String, _ size: Int) -> URL {
    let u = work.appendingPathComponent("src").appendingPathComponent(name)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    var d = Data(count: size); for i in stride(from: 0, to: size, by: 4096) { d[i] = UInt8(i / 4096 % 251) }
    try! d.write(to: u); return u
}
let hu = args.count > 4 ? args[3] : "", hp = args.count > 4 ? args[4] : ""
let mac = HubClient(config: HubConfig(baseURL: base + "/", username: hu, password: hp, device: "Mac"))
let win = HubClient(config: HubConfig(baseURL: base, username: hu, password: hp, device: "Windows"))

// (No 401 test here: on Linux, FoundationNetworking waits forever on a 401 that carries WWW-Authenticate
//  when no session delegate answers the challenge. macOS returns the 401 normally; the clip harness covers it.)

// 1. list
let l: Result<[HubItem], HubError> = wait { mac.listItems(limit: 50, completion: $0) }
if case .success(let items) = l { check("listItems decodes seeded items (\(items.count))", items.count >= 8)
    check("listItems order: pinned, then starred, then newest", items == items.hubOrdered())
    check("displayName for text = first line", items.contains { $0.type == 0 && $0.displayName == "https://github.com/Jeric-X/SyncClipboard" })
} else { check("listItems \(l)", false) }

// 2. upload tricky filename + progress
let tricky = "测试 a+b&c=d %41 #1 😀.txt"
let f1 = makeFile(tricky, 1_500_000)
var progressCalls = 0; var lastSent: Int64 = 0
let u1: Result<HubItem?, HubError> = wait { done in
    mac.upload(fileURL: f1, progress: { s, _ in progressCalls += 1; lastSent = s }, completion: done) }
if case .success(let it?) = u1 {
    check("upload filename round-trips exactly (got \(it.filename ?? "nil"))", it.filename == tricky)
    check("upload size matches (\(it.size ?? -1))", it.size == 1_500_000)
    check("upload from=Mac", it.fromDevice == "Mac")
} else { check("upload tricky \(u1)", false) }
check("upload progress callbacks (\(progressCalls), last \(lastSent))", progressCalls >= 1 && lastSent == 1_500_000)

// 3. bigger upload, star flag
let f2 = makeFile("big_video.mp4", 25_000_000); progressCalls = 0
let u2: Result<HubItem?, HubError> = wait { done in
    mac.upload(fileURL: f2, starred: true, progress: { _, _ in progressCalls += 1 }, completion: done) }
if case .success(let it?) = u2 { check("25 MB upload ok, starred=\(it.starred ?? false), category=\(it.category ?? "")", it.size == 25_000_000 && it.starred == true && it.category == "视频") } else { check("big upload \(u2)", false) }
check("multiple progress callbacks on big upload (\(progressCalls))", progressCalls > 3)

// 4. cancel
let f3 = makeFile("cancel_me.bin", 60_000_000)
var h: HubUploadHandle!
let u3: Result<HubItem?, HubError> = wait { done in
    var fired = false
    h = mac.upload(fileURL: f3, progress: { s, _ in if !fired && s > 0 { fired = true; h.cancel() } }, completion: done) }
if case .failure(let e) = u3 { check("cancel -> .cancelled (\(e))", e.isCancelled) } else { check("cancel produced \(u3)", false) }

// 5. text
let txt = "你好 SyncHub + & = 100% \n第二行"
let t: Result<HubItem?, HubError> = wait { mac.postText(txt, completion: $0) }
if case .success(let it?) = t { check("postText round-trip", it.text == txt.trimmingCharacters(in: .whitespacesAndNewlines) && it.type == 0 && it.fromDevice == "Mac") } else { check("postText \(t)", false) }

// 6. auto receiver
let recv = work.appendingPathComponent("跨端传输文件")
let legacy = work.appendingPathComponent("legacy_last_id.txt")
let r = HubAutoReceiver(stateURL: work.appendingPathComponent("state/state.json"), legacyStateURL: nil,
                        clientProvider: { mac }, directoryProvider: { recv })
var received: [String] = []
r.onReceived = { _, url in received.append(url.lastPathComponent) }
wait { (d: @escaping (Void) -> Void) in r.pollOnce { d(()) } }
let firstId = r.lastId
check("first poll only records latest id (\(firstId)), downloads nothing", firstId > 0 && received.isEmpty)

let w1 = makeFile("来自Windows的文档.pdf", 300_000)
let w2 = makeFile("photo.png", 50_000)
_ = wait { (d: @escaping (Result<HubItem?, HubError>) -> Void) in win.upload(fileURL: w1, progress: { _, _ in }, completion: d) }
_ = wait { (d: @escaping (Result<HubItem?, HubError>) -> Void) in win.upload(fileURL: w2, progress: { _, _ in }, completion: d) }
_ = wait { (d: @escaping (Result<HubItem?, HubError>) -> Void) in win.postText("windows text", completion: d) }
let own = makeFile("mac_own.txt", 1000)
_ = wait { (d: @escaping (Result<HubItem?, HubError>) -> Void) in mac.upload(fileURL: own, progress: { _, _ in }, completion: d) }
var pollRes: Result<Int, HubError>?
r.onPoll = { pollRes = $0 }
wait { (d: @escaping (Void) -> Void) in r.pollOnce { d(()) } }
check("receives the 2 Windows files only (\(received))", received.sorted() == ["photo.png", "来自Windows的文档.pdf"].sorted())
if case .success(let n)? = pollRes { check("onPoll reports 2", n == 2) } else { check("onPoll \(String(describing: pollRes))", false) }
let saved = recv.appendingPathComponent("来自Windows的文档.pdf")
check("saved content identical", (try? Data(contentsOf: saved)) == (try? Data(contentsOf: w1)))
check("no .downloading leftovers", !((try? fm.contentsOfDirectory(atPath: recv.path)) ?? []).contains { $0.hasSuffix(".downloading") })
let idAfter = r.lastId
received = []
wait { (d: @escaping (Void) -> Void) in r.pollOnce { d(()) } }
check("second poll downloads nothing (lastId \(idAfter) -> \(r.lastId))", received.isEmpty)

// same name, different size -> "(1)"; same name same size after state reset -> skipped
let w3 = work.appendingPathComponent("src2/photo.png"); try! fm.createDirectory(at: w3.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data(repeating: 7, count: 1234).write(to: w3)
_ = wait { (d: @escaping (Result<HubItem?, HubError>) -> Void) in win.upload(fileURL: w3, progress: { _, _ in }, completion: d) }
wait { (d: @escaping (Void) -> Void) in r.pollOnce { d(()) } }
check("name clash saved as 'photo (1).png' (\(received))", received == ["photo (1).png"])
received = []
r.lastId = idAfter  // pretend we lost state: must not duplicate photo.png / pdf
wait { (d: @escaping (Void) -> Void) in r.pollOnce { d(()) } }
let names = (try? fm.contentsOfDirectory(atPath: recv.path))?.sorted() ?? []
check("state loss: existing same-size files skipped, no duplicates (\(names))", names == ["photo (1).png", "photo.png", "来自Windows的文档.pdf"].sorted())

// 6b. a file that can never be saved must not block later files forever (skipped after 3 tries)
let blockedFile = work.appendingPathComponent("not_a_dir"); try! Data("x".utf8).write(to: blockedFile)
var target = blockedFile                     // createDirectory fails -> .local error
let r3 = HubAutoReceiver(stateURL: work.appendingPathComponent("state3/state.json"), legacyStateURL: nil,
                         clientProvider: { mac }, directoryProvider: { target })
wait { (d: @escaping (Void) -> Void) in r3.pollOnce { d(()) } }
let bad = makeFile("stuck.bin", 10)
var badId = 0
if case .success(let it?) = wait({ (d: @escaping (Result<HubItem?, HubError>) -> Void) in win.upload(fileURL: bad, progress: { _, _ in }, completion: d) }) { badId = it.id }
for _ in 0..<3 { wait { (d: @escaping (Void) -> Void) in r3.pollOnce { d(()) } } }
check("unsaveable item skipped after 3 failures (lastId \(r3.lastId) >= \(badId))", badId > 0 && r3.lastId >= badId)
target = work.appendingPathComponent("recv3")
var got3: [String] = []
r3.onReceived = { _, url in got3.append(url.lastPathComponent) }
let good = makeFile("after_stuck.bin", 10)
_ = wait { (d: @escaping (Result<HubItem?, HubError>) -> Void) in win.upload(fileURL: good, progress: { _, _ in }, completion: d) }
wait { (d: @escaping (Void) -> Void) in r3.pollOnce { d(()) } }
check("later file still received (\(got3))", got3 == ["after_stuck.bin"])

// 7. legacy migration
try! "4242\n".write(to: legacy, atomically: true, encoding: .utf8)
let r2 = HubAutoReceiver(stateURL: work.appendingPathComponent("state2/state.json"), legacyStateURL: legacy,
                         clientProvider: { mac }, directoryProvider: { recv })
check("migrates ~/.synchub/last_id.txt (\(r2.lastId))", r2.lastId == 4242)

// 8. auth header + errors
let authed = HubClient(config: HubConfig(baseURL: "example.com", username: "u", password: "p:w"))
let req = authed.request(try! authed.url("/api/hub/items"))
check("basic auth header", req.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("u:p:w".utf8).base64EncodedString())
check("scheme defaults to https", req.url?.absoluteString == "https://example.com/api/hub/items")
let anon = HubClient(config: HubConfig(baseURL: base))
check("no auth header when username empty", anon.request(try! anon.url("/x")).value(forHTTPHeaderField: "Authorization") == nil)
let dead = HubClient(config: HubConfig(baseURL: "http://127.0.0.1:1"))
let de: Result<[HubItem], HubError> = wait { dead.listItems(completion: $0) }
if case .failure(.network) = de { check("unreachable server -> network error", true) } else { check("unreachable \(de)", false) }
let nf: Result<[HubItem], HubError> = wait { HubClient(config: HubConfig(baseURL: base + "/nope", username: hu, password: hp)).listItems(completion: $0) }
if case .failure(.http(404, _)) = nf { check("404 mapped: \(nf.mapError { $0 }) ", true) } else { check("404 \(nf)", false) }
// 1.1.1: ordering + storage
func mk(_ id: Int, pinned: Bool = false, starred: Bool = false) -> HubItem {
    try! JSONDecoder().decode(HubItem.self, from: Data("{\"id\":\(id),\"type\":0,\"text\":\"t\(id)\",\"pinned\":\(pinned),\"starred\":\(starred)}".utf8))
}
let ord = [mk(1), mk(2, starred: true), mk(3, pinned: true), mk(4), mk(5, pinned: true, starred: true), mk(6, starred: true)].hubOrdered().map { $0.id }
check("hubOrdered pinned→starred→newest \(ord)", ord == [5, 3, 6, 2, 4, 1])
let sr: Result<HubStorage, HubError> = wait { mac.storage(completion: $0) }
if case .success(let s) = sr {
    check("GET /api/hub/storage decodes (\(s.menuLine))", s.total > 0 && s.used > 0 && s.free >= 0 && s.used <= s.total && s.menuLine.hasPrefix("存储 已用 "))
} else { check("storage \(sr)", false) }
let fixed = HubStorage(total: 63_290_085_376, used: 11_433_066_496, free: 48_619_253_760, hubBytes: 262_000_000)
check("storage menu line = \(fixed.menuLine)", fixed.menuLine == "存储 已用 10.6 GB / 58.9 GB · 剩余 45.3 GB")
check("storage fmt MB / TB / ≥100 GB", HubStorage.fmt(262_000_000) == "250 MB" && HubStorage.fmt(2 * 1_099_511_627_776) == "2.0 TB" && HubStorage.fmt(150 * 1_073_741_824) == "150 GB")
check("usedFraction", abs(fixed.usedFraction - 0.1806) < 0.001 && HubStorage(total: 0, used: 0, free: 0, hubBytes: nil).usedFraction == 0)

check("format bytes", HubFormat.bytes(1536) == "1 KB" && HubFormat.bytes(5_242_880) == "5.00 MB")
check("safeFilename strips path", HubFormat.safeFilename("../../etc/passwd", fallback: "x") == "passwd" && HubFormat.safeFilename("..", fallback: "x") == "x")

// 1.1.2: local copies, notification routing, open plan
let lc = work.appendingPathComponent("lc"); try! fm.createDirectory(at: lc, withIntermediateDirectories: true)
func put(_ n: String, _ size: Int) { try! Data(count: size).write(to: lc.appendingPathComponent(n)) }
put("a.pdf", 10); put("a (1).pdf", 20); put("a (2).pdf", 30); put("noext", 5); put("b (1).txt", 7)
check("localCopy exact name", HubFormat.localCopy(in: lc, filename: "a.pdf", size: 10)?.lastPathComponent == "a.pdf")
check("localCopy finds name (n) copy", HubFormat.localCopy(in: lc, filename: "a.pdf", size: 30)?.lastPathComponent == "a (2).pdf")
check("localCopy size mismatch -> nil", HubFormat.localCopy(in: lc, filename: "a.pdf", size: 99) == nil)
check("localCopy no extension", HubFormat.localCopy(in: lc, filename: "noext", size: 5) != nil)
check("localCopy bare name deleted, (1) remains", HubFormat.localCopy(in: lc, filename: "b.txt", size: 7)?.lastPathComponent == "b (1).txt")
check("localCopy unknown size: exact name only", HubFormat.localCopy(in: lc, filename: "a.pdf", size: nil) != nil && HubFormat.localCopy(in: lc, filename: "b.txt", size: 0) == nil)
try! fm.createDirectory(at: lc.appendingPathComponent("dir.zip"), withIntermediateDirectories: true)
check("localCopy ignores directories", HubFormat.localCopy(in: lc, filename: "dir.zip", size: nil) == nil)
check("alreadyHave still works", HubFormat.alreadyHave(in: lc, filename: "a.pdf", size: 20) && !HubFormat.alreadyHave(in: lc, filename: "a.pdf", size: 0))

let ui = NotificationTap.userInfo(file: lc.appendingPathComponent("a.pdf"))
check("file banner carries path in userInfo", ui["file"] == lc.appendingPathComponent("a.pdf").path)
check("route file banner -> openFile", NotificationTap.route(ui) == .openFile(lc.appendingPathComponent("a.pdf").path))
check("route 1.1.1 banner (reveal key) -> openFile", NotificationTap.route(["reveal": "/x/y.zip"]) == .openFile("/x/y.zip"))
check("route other banners -> showMenu", NotificationTap.route([:]) == .showMenu && NotificationTap.route(["file": ""]) == .showMenu
      && NotificationTap.userInfo(file: nil).isEmpty)

check("plan: existing pdf -> open", LocalFileAction.plan(path: lc.appendingPathComponent("a.pdf").path) == .open(lc.appendingPathComponent("a.pdf")))
put("run.command", 3); put("x.SH", 3)
check("plan: .command / .SH -> reveal only", LocalFileAction.plan(path: lc.appendingPathComponent("run.command").path) == .reveal(lc.appendingPathComponent("run.command"))
      && LocalFileAction.plan(path: lc.appendingPathComponent("x.SH").path) == .reveal(lc.appendingPathComponent("x.SH")))
if case .revealFolder(let d) = LocalFileAction.plan(path: lc.appendingPathComponent("gone.pdf").path) {
    check("plan: deleted file -> reveal folder", d.standardizedFileURL.path == lc.standardizedFileURL.path)
} else { check("plan: deleted file -> reveal folder", false) }
check("plan: folder gone too -> missing", LocalFileAction.plan(path: "/nonexistent_synchub/q/gone.pdf") == .missing)

// download a text-free file item into a receive folder and find it as the local copy (menu "已在本机" path)
let li: Result<[HubItem], HubError> = wait { mac.listItems(limit: 50, completion: $0) }
if case .success(let items) = li, let f = items.first(where: { $0.isFile && ($0.size ?? 0) > 0 }) {
    let rd = work.appendingPathComponent("recv"); try! fm.createDirectory(at: rd, withIntermediateDirectories: true)
    let name = HubFormat.safeFilename(f.filename ?? "", fallback: "file_\(f.id)")
    check("not local before download", HubFormat.localCopy(in: rd, filename: name, size: f.size) == nil)
    let dl: Result<URL, HubError> = wait { c in _ = mac.download(item: f, completion: c) }
    if case .success(let tmp) = dl {
        let dest = HubFormat.uniqueURL(in: rd, filename: name); try! fm.moveItem(at: tmp, to: dest)
        check("downloaded file found as local copy (\(name))", HubFormat.localCopy(in: rd, filename: name, size: f.size) == dest)
    } else { check("download \(dl)", false) }
} else { check("list for download test", false) }

print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
