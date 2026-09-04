import AppKit

struct AnimSpec {
    let row: Int
    let frames: Int
    let fps: Double
    let loops: Bool
}

enum Anim: String, CaseIterable {
    case sleeping, waking, typing, alarmed, celebrate, annoyed

    var spec: AnimSpec {
        switch self {
        case .sleeping:  return AnimSpec(row: 0, frames: 6, fps: 3, loops: true)
        case .waking:    return AnimSpec(row: 1, frames: 6, fps: 2, loops: false)
        case .typing:    return AnimSpec(row: 2, frames: 6, fps: 8, loops: false)
        case .alarmed:   return AnimSpec(row: 3, frames: 6, fps: 8, loops: false)
        case .celebrate: return AnimSpec(row: 4, frames: 6, fps: 8, loops: false)
        case .annoyed:   return AnimSpec(row: 5, frames: 6, fps: 8, loops: false)
        }
    }

    /// Same mapping the Electron build used, so the orc reacts identically.
    static func forHookEvent(_ event: String) -> Anim? {
        switch event {
        case "SessionStart":       return .waking
        case "Stop":               return .celebrate
        case "UserPromptSubmit":   return .typing
        case "PermissionRequest",
             "Notification",
             "PreCompact":         return .alarmed
        case "PostToolUseFailure": return .annoyed
        default:                   return nil
        }
    }
}

/// Frames are pre-sliced at build time, so nothing decodes a 4096² atlas at
/// runtime. They are loaded lazily and cached: a session that never errors
/// never pays for the `annoyed` row.
@MainActor
final class FrameStore {
    static let shared = FrameStore()
    private var cache: [String: CGImage] = [:]

    func image(row: Int, col: Int) -> CGImage? {
        let key = "f\(row)\(col)"
        if let hit = cache[key] { return hit }
        guard let url = Bundle.main.url(forResource: key, withExtension: "png",
                                        subdirectory: "frames")
                ?? Bundle.main.url(forResource: key, withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        cache[key] = img
        return img
    }
}

/// Drives the sprite by swapping `contents` on a layer at the animation's own
/// frame rate (3–8 Hz). There is no render loop: between frames the CPU is idle
/// and the window server keeps compositing what is already there.
@MainActor
final class SpriteAnimator {
    private let layer: CALayer
    private var timer: Timer?
    private(set) var current: Anim = .sleeping
    private var frame = 0
    /// Called when a non-looping animation finishes.
    var onFinish: (() -> Void)?

    init(layer: CALayer) {
        self.layer = layer
        layer.magnificationFilter = .nearest   // pixel art must stay crisp
        layer.minificationFilter = .nearest
        play(.sleeping)
    }

    func play(_ anim: Anim) {
        debugLog("anim: \(current.rawValue) -> \(anim.rawValue) (\(Int(anim.spec.fps))fps, \(anim.spec.loops ? "loop" : "una vez"))")
        timer?.invalidate()
        current = anim
        frame = 0
        show(frame)
        let spec = anim.spec
        let t = Timer(timeInterval: 1.0 / spec.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common keeps the orc animating while a menu is open
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let spec = current.spec
        frame += 1
        if frame >= spec.frames {
            if spec.loops {
                frame = 0
            } else {
                frame = spec.frames - 1
                show(frame)
                timer?.invalidate()
                timer = nil
                debugLog("anim \(current.rawValue) termino")
                onFinish?()
                return
            }
        }
        show(frame)
    }

    private func show(_ index: Int) {
        guard let img = FrameStore.shared.image(row: current.spec.row, col: index) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit cross-fade
        layer.contents = img
        CATransaction.commit()
    }

    func stop() { timer?.invalidate(); timer = nil }
}
