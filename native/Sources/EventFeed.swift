import Foundation
import CoreServices

/// Events come straight from peon-ping's own `.state.json`, which it rewrites on
/// every hook. That is why this app installs no hook of its own and never edits
/// `~/.claude/settings.json`: the exact event name and session id are already
/// there, so watching one small file replaces the transcript-parsing heuristics
/// the Electron build needed.
@MainActor
final class EventFeed {
    struct Session {
        var lastSeen: Date
        var hot: Bool { Date().timeIntervalSince(lastSeen) < 30 }
        var warm: Bool { Date().timeIntervalSince(lastSeen) < 120 }
        var stale: Bool { Date().timeIntervalSince(lastSeen) > 600 }
    }

    private let statePath = Paths.peonDir.appending(path: ".state.json")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var lastStamp: Double = 0
    private var sessions: [String: Session] = [:]
    private var ageTimer: Timer?

    var onEvent: ((Anim) -> Void)?
    var onSessions: (([(hot: Bool, warm: Bool)]) -> Void)?
    /// Fires while a session is actively writing, between lifecycle hooks.
    var onActivity: (() -> Void)?

    private var stream: FSEventStreamRef?

    func start() {
        readState(emit: false)   // adopt current state without animating
        watch()
        watchTranscripts()
        // Sessions cool off on their own; one slow timer is enough to age them.
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneAndPublish() }
        }
        RunLoop.main.add(t, forMode: .common)
        ageTimer = t
    }

    /// Watches the *directory*, not the file. peon-ping rewrites `.state.json`
    /// atomically, which swaps the inode and leaves a file-descriptor watch
    /// pointing at an orphan that never changes again.
    private func watch() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        fd = open(Paths.peonDir.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.watch() }
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: .main)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readState(emit: true) }
        }
        s.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd); self.fd = -1
        }
        s.resume()
        source = s
    }

    private func readState(emit: Bool) {
        let state = readJSON(statePath)
        guard let active = state["last_active"] as? [String: Any],
              let stamp = active["timestamp"] as? Double
        else { return }

        let sessionID = active["session_id"] as? String ?? "?"
        sessions[sessionID] = Session(lastSeen: Date(timeIntervalSince1970: stamp))

        if stamp > lastStamp {
            lastStamp = stamp
            if emit, let event = active["event"] as? String {
                if let anim = Anim.forHookEvent(event) {
                    debugLog("evento \(event) -> \(anim.rawValue)")
                    onEvent?(anim)
                } else {
                    debugLog("evento \(event) -> (sin animacion)")
                }
            }
        }
        pruneAndPublish()
    }

    private func pruneAndPublish() {
        sessions = sessions.filter { !$0.value.stale }
        let list = sessions.values
            .sorted { $0.lastSeen < $1.lastSeen }
            .map { (hot: $0.hot, warm: $0.warm) }
        onSessions?(list)
    }

    /// peon-ping only writes state on lifecycle hooks — a prompt starting and a
    /// turn ending. A long turn full of tool calls produces nothing in between,
    /// so the orc would fall asleep mid-work. The transcripts *are* appended
    /// continuously, so their mtime is the missing "still working" signal.
    /// FSEvents delivers it with a 1s coalescing window: no polling.
    private func watchTranscripts() {
        let dir = Paths.home.appending(path: ".claude/projects").path
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let feed = Unmanaged<EventFeed>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { feed.transcriptsChanged(Array(list.prefix(count))) }
        }
        guard let s = FSEventStreamCreate(
            nil, callback, &ctx, [dir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,   // coalesce a burst of writes into one callback per second
            // UseCFTypes is required: without it eventPaths is a C char** and
            // reading it as an NSArray yields garbage.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                     | kFSEventStreamCreateFlagNoDefer
                                     | kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        let started = FSEventStreamStart(s)
        debugLog("FSEvents sobre \(dir): started=\(started)")
        stream = s
    }

    fileprivate func transcriptsChanged(_ paths: [String]) {
        debugLog("FSEvents callback: \(paths.count) rutas -> \(paths.prefix(2).map { ($0 as NSString).lastPathComponent })")
        let now = Date()
        var touched = false
        for path in paths where path.hasSuffix(".jsonl") {
            let sid = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".jsonl", with: "")
            sessions[sid] = Session(lastSeen: now)
            touched = true
        }
        guard touched else { return }
        debugLog("actividad en transcripts (\(paths.count) rutas)")
        onActivity?()
        pruneAndPublish()
    }

    deinit {
        source?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
