import Foundation

/// Everything peon-ping already stores on disk. This app is a view over those
/// files plus the `peon` CLI — it never keeps a second source of truth.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let peonDir   = home.appending(path: ".claude/hooks/peon-ping")
    static let peonConf  = peonDir.appending(path: "config.json")
    static let pausedFile = peonDir.appending(path: ".paused")
    static let openpeon  = home.appending(path: ".openpeon")
    static let packsDir  = openpeon.appending(path: "packs")
    static let modeFile  = openpeon.appending(path: "pet-mode")
    static let petConf   = openpeon.appending(path: "pet-native.json")
    static let eventFeed = openpeon.appending(path: "pet-events.jsonl")
    static let hookScript = openpeon.appending(path: "pet-hook.sh")
    static let claudeSettings = home.appending(path: ".claude/settings.json")

    static let peonCandidates = [
        "/opt/homebrew/bin/peon", "/usr/local/bin/peon",
        home.appending(path: ".local/bin/peon").path,
    ]
    static var peonBin: String? {
        peonCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}

enum PetMode: String, CaseIterable {
    case follow, always, off
}

/// Fire-and-forget wrapper around the peon CLI.
@discardableResult
func runPeon(_ args: [String]) -> Bool {
    guard let bin = Paths.peonBin else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    return true
}

func readJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

func writeJSON(_ url: URL, _ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

struct PeonConfig {
    var raw: [String: Any]

    static func load() -> PeonConfig { PeonConfig(raw: readJSON(Paths.peonConf)) }

    var pack: String { raw["default_pack"] as? String ?? "" }
    var volume: Double { raw["volume"] as? Double ?? 0.5 }
    var desktopNotifications: Bool { raw["desktop_notifications"] as? Bool ?? true }
    var categories: [String: Bool] {
        (raw["categories"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
    }

    /// Only the touched keys are rewritten; the rest of the file is preserved.
    static func setCategory(_ key: String, _ value: Bool) {
        var cfg = readJSON(Paths.peonConf)
        var cats = cfg["categories"] as? [String: Any] ?? [:]
        cats[key] = value
        cfg["categories"] = cats
        writeJSON(Paths.peonConf, cfg)
    }

    static func setDesktopNotifications(_ value: Bool) {
        var cfg = readJSON(Paths.peonConf)
        cfg["desktop_notifications"] = value
        writeJSON(Paths.peonConf, cfg)
    }

    static var isPaused: Bool {
        FileManager.default.fileExists(atPath: Paths.pausedFile.path)
    }
}

struct SoundPack {
    let name: String
    let label: String
    let language: String
}

/// Human names for the language codes the packs ship with.
let LANGUAGE_NAMES: [String: String] = [
    "es": "Español", "en": "Inglés", "fr": "Francés",
    "ru": "Ruso", "cs": "Checo", "pl": "Polaco",
]

func languageLabel(_ code: String) -> String {
    LANGUAGE_NAMES[code] ?? code.uppercased()
}

/// Packs grouped by language, the user's own language first.
func packsByLanguage() -> [(language: String, packs: [SoundPack])] {
    let all = installedPacks()
    let preferred = Locale.current.language.languageCode?.identifier ?? "es"
    let groups = Dictionary(grouping: all, by: { $0.language })
    return groups
        .map { (language: $0.key, packs: $0.value) }
        .sorted { a, b in
            if a.language == preferred { return true }
            if b.language == preferred { return false }
            if a.packs.count != b.packs.count { return a.packs.count > b.packs.count }
            return a.language < b.language
        }
}

func installedPacks() -> [SoundPack] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: Paths.packsDir.path) else { return [] }
    return names.compactMap { name -> SoundPack? in
        let manifest = Paths.packsDir.appending(path: "\(name)/openpeon.json")
        guard fm.fileExists(atPath: manifest.path) else { return nil }
        let m = readJSON(manifest)
        return SoundPack(name: name,
                         label: m["display_name"] as? String ?? name,
                         language: m["language"] as? String ?? "??")
    }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
}

/// This app's own preferences, deliberately separate from peon-ping's.
struct PetPrefs {
    static func load() -> [String: Any] { readJSON(Paths.petConf) }

    static var size: CGFloat {
        get {
            let v = load()["size"] as? Double ?? 200
            return CGFloat(min(max(v, 120), 420))
        }
        set {
            var c = load(); c["size"] = Double(newValue); writeJSON(Paths.petConf, c)
        }
    }

    static var mode: PetMode {
        get {
            let raw = (try? String(contentsOf: Paths.modeFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PetMode(rawValue: raw) ?? .follow
        }
        set {
            try? FileManager.default.createDirectory(
                at: Paths.openpeon, withIntermediateDirectories: true)
            try? (newValue.rawValue + "\n").write(to: Paths.modeFile, atomically: true, encoding: .utf8)
        }
    }
}


/// Opt-in tracing; silent unless PEONPET_DEBUG is set.
let peonDebug = ProcessInfo.processInfo.environment["PEONPET_DEBUG"] != nil
func debugLog(_ msg: @autoclosure () -> String) {
    guard peonDebug else { return }
    FileHandle.standardError.write(Data(("[peonpet] " + msg() + "\n").utf8))
}
