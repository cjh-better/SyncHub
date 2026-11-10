// Linux test harness for HubCore.swift (run against a LOCAL synchub_server.py only).
// Build: swiftc ../../Sources/SyncHub/HubCore.swift main.swift -o harness
// Run:   ./harness http://127.0.0.1:PORT /tmp/workdir
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
let mac = HubClient(config: HubConfig(baseURL: base + "/", device: "Mac"))
let win = HubClient(config: HubConfig(baseURL: base, device: "Windows"))

// 1. list
let l: Result<[HubItem], HubError> = wait { mac.listItems(limit: 50, completion: $0) }
if case .success(let items) = l { check("listItems decodes seeded items (\(items.count))", items.count >= 8)
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
check("no auth header when username empty", mac.request(try! mac.url("/x")).value(forHTTPHeaderField: "Authorization") == nil)
let dead = HubClient(config: HubConfig(baseURL: "http://127.0.0.1:1"))
let de: Result<[HubItem], HubError> = wait { dead.listItems(completion: $0) }
if case .failure(.network) = de { check("unreachable server -> network error", true) } else { check("unreachable \(de)", false) }
let nf: Result<[HubItem], HubError> = wait { HubClient(config: HubConfig(baseURL: base + "/nope")).listItems(completion: $0) }
if case .failure(.http(404, _)) = nf { check("404 mapped: \(nf.mapError { $0 }) ", true) } else { check("404 \(nf)", false) }
check("format bytes", HubFormat.bytes(1536) == "1 KB" && HubFormat.bytes(5_242_880) == "5.00 MB")
check("safeFilename strips path", HubFormat.safeFilename("../../etc/passwd", fallback: "x") == "passwd" && HubFormat.safeFilename("..", fallback: "x") == "x")

print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
