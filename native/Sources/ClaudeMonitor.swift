import AppKit

/// Knows whether Claude is open. The desktop app is observed through
/// NSWorkspace, which reports launch and termination the instant they happen —
/// no polling, no `ps` parsing, and no way for a browser-spawned `claude.exe`
/// to be mistaken for the app.
@MainActor
final class ClaudeMonitor {
    /// Overridable so the launch/terminate path can be exercised against a
    /// throwaway app instead of having to quit Claude itself.
    static let bundleID = ProcessInfo.processInfo.environment["PEONPET_WATCH_BUNDLE"]
        ?? "com.anthropic.claudefordesktop"

    var onChange: ((Bool) -> Void)?
    /// Fires on every slow tick, whether or not the state changed.
    var onTick: (() -> Void)?
    private(set) var isRunning = false
    private var cliTimer: Timer?

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard Self.isClaude(note) else { return }
                self?.update()
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard Self.isClaude(note) else { return }
                self?.update()
            }
        }

        // The CLI is not an app bundle, so NSWorkspace cannot see it. A slow
        // poll covers `claude` in a terminal without costing anything.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
                self?.onTick?()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        cliTimer = t

        update()
    }

    private static func isClaude(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == bundleID
    }

    private var appRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// A `claude` process attached to a real terminal. Anything without a tty is
    /// a background helper (browser MCP servers show up as `claude.exe`).
    ///
    /// Read straight from the kernel process table: spawning `sh -c "ps | awk"`
    /// every tick meant thousands of processes a day for one boolean.
    private var cliRunning: Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }

        for i in 0..<(size / stride) {
            var entry = procs[i]
            // NODEV means no controlling terminal, i.e. not an interactive session
            if entry.kp_eproc.e_tdev == -1 { continue }
            let name = withUnsafeBytes(of: &entry.kp_proc.p_comm) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if name == "claude" || name == "claude.exe" { return true }
        }
        return false
    }

    private func update() {
        let app = appRunning
        let cli = app ? false : cliRunning   // skip the ps call when the app already answers
        let now = app || cli
        guard now != isRunning else { return }
        debugLog("claude: app=\(app) cli=\(cli) -> \(now ? "abierto" : "cerrado")")
        isRunning = now
        onChange?(now)
    }
}
