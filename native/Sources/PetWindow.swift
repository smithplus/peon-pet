import AppKit

/// Borderless, transparent, always-on-top window holding the orc.
@MainActor
final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }      // never steals focus
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetView: NSView {
    private let spriteLayer = CALayer()
    private let borderLayer = CALayer()
    private var dotLayers: [CALayer] = []
    private var animator: SpriteAnimator!

    private let gripSize: CGFloat = 20
    private var gripLayers: [CALayer] = []

    /// nil while idle; otherwise the corner being dragged.
    private enum Corner { case tl, tr, bl, br }
    private var activeCorner: Corner?
    private var anchorPoint: NSPoint = .zero
    private var dragOffset: NSSize = .zero
    private var isMoving = false

    var anySessionHot = false
    private var isActive = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        buildLayers()
        animator = SpriteAnimator(layer: spriteLayer)
        animator.onFinish = { [weak self] in
            guard let self else { return }
            // Same idle rule as the Electron build
            self.play(self.anySessionHot ? .typing : .sleeping)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayers() {
        guard let root = layer else { return }
        spriteLayer.contentsGravity = .resizeAspect
        root.addSublayer(spriteLayer)

        if let url = Bundle.main.url(forResource: "orc-borders", withExtension: "png"),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            borderLayer.contents = img
            borderLayer.magnificationFilter = .nearest
            root.addSublayer(borderLayer)
        }

        for _ in 0..<10 {
            let dot = CALayer()
            dot.cornerRadius = 3
            dot.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.3, blue: 0.2, alpha: 1).cgColor
            dot.isHidden = true
            root.addSublayer(dot)
            dotLayers.append(dot)
        }

        for _ in 0..<4 {
            let g = CALayer()
            g.borderColor = NSColor(white: 1, alpha: 0.8).cgColor
            g.borderWidth = 2
            g.opacity = 0
            root.addSublayer(g)
            gripLayers.append(g)
        }
    }

    override func layout() {
        super.layout()
        let s = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = s * 0.05
        spriteLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        borderLayer.frame = bounds
        layoutDots()
        let g = gripSize
        gripLayers[0].frame = NSRect(x: 0, y: bounds.height - g, width: g, height: g)      // tl
        gripLayers[1].frame = NSRect(x: bounds.width - g, y: bounds.height - g, width: g, height: g)
        gripLayers[2].frame = NSRect(x: 0, y: 0, width: g, height: g)                       // bl
        gripLayers[3].frame = NSRect(x: bounds.width - g, y: 0, width: g, height: g)
        CATransaction.commit()
    }

    // MARK: - Session dots

    private var sessions: [(hot: Bool, warm: Bool)] = []

    func setSessions(_ list: [(hot: Bool, warm: Bool)]) {
        let next = Array(list.prefix(10))
        // The age timer republishes every 10s; skip the layout when nothing moved
        if next.count == sessions.count,
           zip(next, sessions).allSatisfy({ $0.hot == $1.hot && $0.warm == $1.warm }) {
            return
        }
        sessions = next
        anySessionHot = next.contains { $0.hot }
        debugLog("sesiones: \(sessions.count) (activas=\(sessions.filter { $0.hot }.count), tibias=\(sessions.filter { $0.warm && !$0.hot }.count))")
        layoutDots()
    }

    private func layoutDots() {
        let scale = bounds.width / 200
        let size = 6 * scale, gap = 4 * scale
        let total = CGFloat(sessions.count) * size + max(0, CGFloat(sessions.count - 1)) * gap
        var x = (bounds.width - total) / 2
        let y = bounds.height - 12 * scale

        for (i, dot) in dotLayers.enumerated() {
            guard i < sessions.count else { dot.isHidden = true; continue }
            let s = sessions[i]
            dot.isHidden = false
            dot.frame = NSRect(x: x, y: y, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = s.hot
                ? NSColor(calibratedRed: 0.27, green: 1.0, blue: 0.27, alpha: 1).cgColor
                : s.warm
                    ? NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.10, alpha: 1).cgColor
                    : NSColor(white: 0.2, alpha: 1).cgColor
            // The pulse runs on the render server: zero CPU between frames.
            if s.hot {
                if dot.animation(forKey: "pulse") == nil {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = 0.45; a.toValue = 1.0
                    a.duration = 1.05
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    dot.add(a, forKey: "pulse")
                }
            } else {
                dot.removeAnimation(forKey: "pulse")
                dot.opacity = 1
            }
            x += size + gap
        }
    }

    /// Nudge into the working animation without interrupting whatever is playing.
    func wakeIfSleeping() {
        if animator.current == .sleeping {
            debugLog("actividad detectada estando dormido -> despierta")
            animator.play(.typing)
        }
    }

    /// Off-screen frames cost the same as visible ones. Park the animation
    /// whenever the orc is not on screen.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        debugLog("orco \(active ? "activo" : "en pausa (oculto)")")
        if active { animator.play(animator.current) } else { animator.stop() }
    }

    func play(_ anim: Anim) {
        guard isActive else { return }
        // Waking only makes sense out of sleep, matching the original
        if anim == .waking && animator.current != .sleeping { return }
        animator.play(anim)
    }

    // MARK: - Hover affordance

    override func mouseEntered(with event: NSEvent) { setGrips(visible: true) }
    override func mouseExited(with event: NSEvent) { if activeCorner == nil { setGrips(visible: false) } }

    private func setGrips(visible: Bool) {
        for g in gripLayers { g.opacity = visible ? 0.55 : 0 }
    }

    // MARK: - Drag to move, corner drag to resize

    private func corner(at p: NSPoint) -> Corner? {
        let g = gripSize
        if p.x <= g && p.y >= bounds.height - g { return .tl }
        if p.x >= bounds.width - g && p.y >= bounds.height - g { return .tr }
        if p.x <= g && p.y <= g { return .bl }
        if p.x >= bounds.width - g && p.y <= g { return .br }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let p = convert(event.locationInWindow, from: nil)

        if let c = corner(at: p) {
            activeCorner = c
            let f = win.frame
            // Pin the opposite corner in screen space
            switch c {
            case .br: anchorPoint = NSPoint(x: f.minX, y: f.maxY)
            case .bl: anchorPoint = NSPoint(x: f.maxX, y: f.maxY)
            case .tr: anchorPoint = NSPoint(x: f.minX, y: f.minY)
            case .tl: anchorPoint = NSPoint(x: f.maxX, y: f.minY)
            }
            setGrips(visible: true)
            return
        }

        isMoving = true
        debugLog("arrastre iniciado")
        let origin = win.frame.origin
        let mouse = NSEvent.mouseLocation
        dragOffset = NSSize(width: mouse.x - origin.x, height: mouse.y - origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let mouse = NSEvent.mouseLocation

        if activeCorner != nil {
            let side = max(abs(mouse.x - anchorPoint.x), abs(mouse.y - anchorPoint.y))
            let size = min(max(side, 120), 420)
            var origin = NSPoint.zero
            switch activeCorner! {
            case .br: origin = NSPoint(x: anchorPoint.x, y: anchorPoint.y - size)
            case .bl: origin = NSPoint(x: anchorPoint.x - size, y: anchorPoint.y - size)
            case .tr: origin = NSPoint(x: anchorPoint.x, y: anchorPoint.y)
            case .tl: origin = NSPoint(x: anchorPoint.x - size, y: anchorPoint.y)
            }
            win.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)),
                         display: true)
            return
        }

        if isMoving {
            win.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.width,
                                       y: mouse.y - dragOffset.height))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if activeCorner != nil, let win = window {
            debugLog("resize soltado -> \(Int(win.frame.width))px")
            PetPrefs.size = win.frame.width
            NotificationCenter.default.post(name: .petSizeChanged, object: nil)
        }
        activeCorner = nil
        isMoving = false
    }
}

extension Notification.Name {
    static let petSizeChanged = Notification.Name("petSizeChanged")
}
