// UploadManager.swift — upload queue (one file at a time, streamed from disk), cancel / retry, folder → zip.
import AppKit
import Combine

final class UploadJob: ObservableObject, Identifiable {
    enum Phase: Equatable { case preparing, waiting, uploading, done, failed(String), cancelled }

    let id = UUID()
    let source: URL                 // what the user picked (file or folder)
    @Published var fileURL: URL?    // what is actually uploaded (zip for folders)
    @Published var name: String
    @Published var size: Int64
    @Published var phase: Phase
    @Published var sent: Int64 = 0
    @Published var speed: Double = 0        // bytes per second
    var deleteAfter: Bool                   // temp files (clipboard image, zipped folder)
    var handle: HubUploadHandle?
    var started = Date()
    fileprivate var lastUI = Date.distantPast

    init(source: URL, fileURL: URL?, name: String, size: Int64, phase: Phase, deleteAfter: Bool) {
        self.source = source; self.fileURL = fileURL; self.name = name; self.size = size
        self.phase = phase; self.deleteAfter = deleteAfter
    }

    var fraction: Double { size > 0 ? min(1, Double(sent) / Double(size)) : (phase == .done ? 1 : 0) }
    var isActive: Bool { [.preparing, .waiting, .uploading].contains(phase) }
    var isFailed: Bool { if case .failed = phase { return true }; return false }
}

final class UploadManager: ObservableObject {
    static let shared = UploadManager()
    @Published private(set) var jobs: [UploadJob] = []
    /// Set by AppDelegate.
    var clientProvider: () -> HubClient? = { nil }
    var onJobFinished: ((UploadJob) -> Void)?
    var onChange: (() -> Void)?
    private var bag = Set<AnyCancellable>()

    var activeJobs: [UploadJob] { jobs.filter { $0.isActive } }
    var totalFraction: Double {
        let a = jobs.filter { $0.isActive || $0.phase == .done }
        let total = a.reduce(Int64(0)) { $0 + max($1.size, 0) }
        guard total > 0 else { return 0 }
        return Double(a.reduce(Int64(0)) { $0 + ($1.phase == .done ? $1.size : $1.sent) }) / Double(total)
    }

    // MARK: enqueue

    /// `temporary`: delete the file after a successful upload (used for clipboard images).
    func enqueue(_ urls: [URL], temporary: Bool = false) {
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {                  // folders and bundles (.app, .pages…) are zipped first
                let job = UploadJob(source: u, fileURL: nil, name: u.lastPathComponent + ".zip", size: 0,
                                    phase: .preparing, deleteAfter: true)
                add(job)
                zipFolder(u, job: job)
            } else {
                let size = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
                add(UploadJob(source: u, fileURL: u, name: u.lastPathComponent, size: size,
                              phase: .waiting, deleteAfter: temporary))
            }
        }
        pump()
    }

    private func add(_ job: UploadJob) {
        job.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.onChange?() } }.store(in: &bag)
        jobs.append(job)
        onChange?()
    }

    private func zipFolder(_ folder: URL, job: UploadJob) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("synchub-zip-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let zip = tmpDir.appendingPathComponent(folder.lastPathComponent + ".zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
            var ok = false
            do { try p.run(); p.waitUntilExit(); ok = p.terminationStatus == 0 } catch {}
            let size = ((try? FileManager.default.attributesOfItem(atPath: zip.path))?[.size] as? NSNumber)?.int64Value ?? 0
            DispatchQueue.main.async {
                guard job.phase == .preparing else { try? FileManager.default.removeItem(at: tmpDir); return }
                if ok { job.fileURL = zip; job.size = size; job.phase = .waiting }
                else { job.phase = .failed("压缩文件夹失败") }
                self.pump()
            }
        }
    }

    // MARK: queue

    private func pump() {
        guard !jobs.contains(where: { $0.phase == .uploading }),
              let next = jobs.first(where: { $0.phase == .waiting }) else { onChange?(); return }
        start(next)
    }

    private func start(_ job: UploadJob) {
        guard let file = job.fileURL else { job.phase = .failed("文件不存在"); pump(); return }
        guard let client = clientProvider() else { job.phase = .failed("请先在设置中填写服务器地址"); pump(); return }
        job.phase = .uploading
        job.sent = 0; job.speed = 0; job.started = Date()
        onChange?()
        job.handle = client.upload(fileURL: file, filename: job.name, progress: { [weak job] sent, _ in
            guard let job = job else { return }
            let now = Date()
            guard now.timeIntervalSince(job.lastUI) > 0.12 else { return }   // throttle UI updates
            job.lastUI = now
            DispatchQueue.main.async {
                job.sent = sent
                job.speed = Double(sent) / max(0.1, now.timeIntervalSince(job.started))
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    job.sent = job.size; job.phase = .done
                    if job.deleteAfter, let f = job.fileURL { try? FileManager.default.removeItem(at: f) }
                case .failure(let e):
                    job.phase = e.isCancelled ? .cancelled : .failed(e.localizedDescription)
                }
                job.handle = nil
                self?.onJobFinished?(job)
                self?.pump()
            }
        })
    }

    func cancel(_ job: UploadJob) {
        switch job.phase {
        case .uploading: job.handle?.cancel()
        case .waiting, .preparing: job.phase = .cancelled; pump()
        default: break
        }
    }

    func cancelAll() { jobs.filter { $0.isActive }.forEach(cancel) }

    func retry(_ job: UploadJob) {
        guard job.isFailed || job.phase == .cancelled else { return }
        var isDir: ObjCBool = false
        if job.fileURL == nil, FileManager.default.fileExists(atPath: job.source.path, isDirectory: &isDir), isDir.boolValue {
            job.phase = .preparing; zipFolder(job.source, job: job); return
        }
        job.phase = .waiting; job.sent = 0
        pump()
    }

    /// Drop finished rows (called when the window closes / auto-closes).
    func clearFinished() {
        for j in jobs where !j.isActive && j.deleteAfter && j.phase != .done {
            if let f = j.fileURL { try? FileManager.default.removeItem(at: f) }
        }
        jobs.removeAll { !$0.isActive }
        onChange?()
    }
}
