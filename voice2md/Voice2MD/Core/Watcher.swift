import Foundation
import CoreServices

final class Watcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.adrianprecub.Voice2MD.watcher")
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<URL>.Continuation?
    private var extensionAllowlist: Set<String>
    private var debounceTasks: [URL: Task<Void, Never>] = [:]

    init(extensionAllowlist: [String]) {
        self.extensionAllowlist = Set(extensionAllowlist.map { $0.lowercased() })
    }

    deinit { stop() }

    func updateAllowlist(_ exts: [String]) {
        queue.sync { self.extensionAllowlist = Set(exts.map { $0.lowercased() }) }
    }

    func start(watching folder: URL) -> AsyncStream<URL> {
        stop()
        let (stream, continuation) = AsyncStream<URL>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        let pathsToWatch = [folder.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        )

        guard let fsStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            continuation.finish()
            AppLog.watcher.error("FSEventStreamCreate failed for \(folder.path, privacy: .public)")
            return stream
        }

        FSEventStreamSetDispatchQueue(fsStream, queue)
        FSEventStreamStart(fsStream)
        self.stream = fsStream

        AppLog.watcher.info("watcher started on \(folder.path, privacy: .public)")
        return stream
    }

    func stop() {
        queue.sync {
            if let s = self.stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                self.stream = nil
            }
            self.continuation?.finish()
            self.continuation = nil
            for task in self.debounceTasks.values { task.cancel() }
            self.debounceTasks.removeAll()
        }
    }

    private static let eventCallback: FSEventStreamCallback = { (
        _, info, numEvents, eventPaths, eventFlags, _
    ) in
        guard let info else { return }
        let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()

        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let paths = (cfArray as NSArray).compactMap { $0 as? String }

        let flagsBuf = UnsafeBufferPointer(start: eventFlags, count: numEvents)
        let flags = Array(flagsBuf)

        watcher.handle(paths: paths, flags: flags)
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, eventFlags) in zip(paths, flags) {
            let url = URL(fileURLWithPath: path)
            guard extensionAllowlist.contains(url.pathExtension.lowercased()) else { continue }

            let isRemoved = (eventFlags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
            if isRemoved { continue }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }

            scheduleDebounce(for: url)
        }
    }

    private func scheduleDebounce(for url: URL) {
        debounceTasks[url]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.debounce(url: url)
        }
        debounceTasks[url] = task
    }

    private func debounce(url: URL) async {
        var lastSize: Int64? = nil
        for _ in 0..<60 {
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }

            guard let size = Self.fileSize(url) else {
                queue.sync { _ = debounceTasks.removeValue(forKey: url) }
                return
            }
            if let last = lastSize, last == size, size > 0 {
                queue.sync {
                    continuation?.yield(url)
                    _ = debounceTasks.removeValue(forKey: url)
                }
                return
            }
            lastSize = size
        }
        queue.sync {
            AppLog.watcher.warning("debounce timeout, emitting \(url.lastPathComponent, privacy: .public)")
            continuation?.yield(url)
            _ = debounceTasks.removeValue(forKey: url)
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let s = v.fileSize else { return nil }
        return Int64(s)
    }
}
