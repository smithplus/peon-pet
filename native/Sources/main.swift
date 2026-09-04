import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var petWindow: PetWindow!
    private var petView: PetView!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settingsModel = SettingsModel()
    private var editorWindow: NSWindow?
    private let editorModel = SoundEditorModel()

    private let monitor = ClaudeMonitor()
    private let feed = EventFeed()
    private var petVisible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies fighting over the same window and state files is a debugging
        // trap; refuse to be the second one.
        let me = ProcessInfo.processInfo.processIdentifier
        let twins = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.martinsmith.peonpet")
            .filter { $0.processIdentifier != me }
        if !twins.isEmpty {
            debugLog("ya hay otra instancia (PID \(twins[0].processIdentifier)); salgo")
            NSApp.terminate(nil)
            return
        }

        buildPetWindow()
        buildStatusItem()

        feed.onEvent = { [weak self] anim in self?.petView.play(anim) }
        feed.onSessions = { [weak self] list in self?.petView.setSessions(list) }
        feed.onActivity = { [weak self] in self?.petView.wakeIfSleeping() }
        feed.start()

        monitor.onChange = { [weak self] _ in self?.applyVisibility() }
        // The mode file can also change from outside (CLI, another session)
        monitor.onTick = { [weak self] in self?.applyVisibilityIfModeChanged() }
        monitor.start()

        NotificationCenter.default.addObserver(
            forName: .petModeChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyVisibility() }
            }
        NotificationCenter.default.addObserver(
            forName: .petSizeChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsModel.size = Double(PetPrefs.size) }
            }

        settingsModel.onSize = { [weak self] size in self?.resizePet(to: size) }
        settingsModel.onOpenEditor = { [weak self] in self?.openEditor() }
        settingsModel.onVisible = { [weak self] on in
            self?.petVisible = on
            self?.applyVisibility()
        }

        applyVisibility()

        // Smoke-test hook: lets the settings window be exercised headlessly
        if ProcessInfo.processInfo.environment["PEONPET_LOGINTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    let svc = SMAppService.mainApp
                    debugLog("login: estado inicial=\(svc.status.rawValue)")
                    do { try svc.register(); debugLog("login: register OK -> \(svc.status.rawValue)") }
                    catch { debugLog("login: register FALLO -> \(error.localizedDescription)") }
                    do { try svc.unregister(); debugLog("login: unregister OK -> \(svc.status.rawValue)") }
                    catch { debugLog("login: unregister fallo -> \(error.localizedDescription)") }
                }
            }
        }
        if ProcessInfo.processInfo.environment["PEONPET_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.editorModel.selfTest() }
            }
        }
        if ProcessInfo.processInfo.environment["PEONPET_OPEN_EDITOR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.openEditor() }
            }
        }
        if ProcessInfo.processInfo.environment["PEONPET_OPEN_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.openSettings() }
            }
        }
    }

    // MARK: - Pet window

    private func buildPetWindow() {
        let size = PetPrefs.size
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.minX + 20, y: screen.minY + 20)

        petWindow = PetWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        petWindow.isOpaque = false
        petWindow.backgroundColor = .clear
        petWindow.hasShadow = false
        petWindow.level = .floating
        petWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        petWindow.ignoresMouseEvents = false
        petWindow.isMovableByWindowBackground = false

        petView = PetView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        petView.autoresizingMask = [.width, .height]
        petWindow.contentView = petView
        petWindow.orderFrontRegardless()
    }

    private func resizePet(to size: CGFloat) {
        guard petWindow != nil else { return }
        var frame = petWindow.frame
        // Keep the bottom-left corner pinned, like the docked widget it is
        frame.size = NSSize(width: size, height: size)
        petWindow.setFrame(frame, display: true)
        PetPrefs.size = size
    }

    private var lastMode: PetMode = .follow

    private func applyVisibilityIfModeChanged() {
        let m = PetPrefs.mode
        guard m != lastMode else { return }
        debugLog("modo cambiado desde afuera: \(lastMode.rawValue) -> \(m.rawValue)")
        lastMode = m
        applyVisibility()
    }

    /// One place decides whether the orc is on screen: the mode, the manual
    /// hide toggle, and — in follow mode — whether Claude is actually running.
    private func applyVisibility() {
        let shouldShow: Bool
        switch PetPrefs.mode {
        case .off:    shouldShow = false
        case .always: shouldShow = petVisible
        case .follow: shouldShow = petVisible && monitor.isRunning
        }
        lastMode = PetPrefs.mode
        debugLog("visibilidad: modo=\(PetPrefs.mode.rawValue) claude=\(monitor.isRunning) -> \(shouldShow ? "visible" : "oculto")")
        if shouldShow {
            petWindow.orderFrontRegardless()
        } else {
            petWindow.orderOut(nil)
        }
        petView.setActive(shouldShow)
        rebuildMenu()
    }

    // MARK: - Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "orc-dock-icon", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.title = "🧌"
            }
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusItem?.menu = makeMenu()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeMenu() }

    private func makeMenu() -> NSMenu {
        let cfg = PeonConfig.load()
        let menu = NSMenu()
        menu.delegate = self

        let packLabel = installedPacks().first { $0.name == cfg.pack }?.label ?? cfg.pack
        menu.addItem(disabled(packLabel.isEmpty ? "peon-ping" : packLabel))
        menu.addItem(disabled(PeonConfig.isPaused ? "⏸  Sonidos en pausa" : "▶  Sonidos activos"))
        menu.addItem(.separator())

        add(menu, PeonConfig.isPaused ? "Reanudar sonidos" : "Pausar sonidos", #selector(togglePause))
        add(menu, "Probar sonido", #selector(testSound))
        menu.addItem(.separator())

        // Voz
        let voice = NSMenu()
        for group in packsByLanguage() {
            let sub = NSMenu()
            for p in group.packs {
                let item = NSMenuItem(title: p.label, action: #selector(pickVoice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.name
                item.state = p.name == cfg.pack ? .on : .off
                sub.addItem(item)
            }
            let head = NSMenuItem(title: "\(languageLabel(group.language))  (\(group.packs.count))",
                                  action: nil, keyEquivalent: "")
            head.submenu = sub
            voice.addItem(head)
        }
        let voiceItem = NSMenuItem(title: "Voz", action: nil, keyEquivalent: "")
        voiceItem.submenu = voice
        menu.addItem(voiceItem)

        // Tamaño
        let sizes = NSMenu()
        for (px, label) in [(140, "Pequeño"), (200, "Mediano"), (280, "Grande"), (360, "Enorme")] {
            let item = NSMenuItem(title: "\(label) (\(px)px)",
                                  action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = px
            item.state = Int(PetPrefs.size) == px ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Tamaño", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        // Modo
        let modes = NSMenu()
        for (mode, label) in [(PetMode.follow, "Seguir a Claude"),
                              (PetMode.always, "Siempre encendido"),
                              (PetMode.off, "Apagado")] {
            let item = NSMenuItem(title: label, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = PetPrefs.mode == mode ? .on : .off
            modes.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Cuándo se muestra", action: nil, keyEquivalent: "")
        modeItem.submenu = modes
        menu.addItem(modeItem)

        menu.addItem(.separator())
        add(menu, petVisible ? "Ocultar orco" : "Mostrar orco", #selector(toggleVisible))
        add(menu, "Ajustes…", #selector(openSettings), key: ",")
        add(menu, "Editar sonidos…", #selector(openEditor), key: "e")
        menu.addItem(.separator())
        add(menu, "Salir", #selector(quit), key: "q")
        return menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    // MARK: - Actions

    @objc private func togglePause() {
        debugLog("menu: \(PeonConfig.isPaused ? "reanudar" : "pausar") sonidos")
        runPeon([PeonConfig.isPaused ? "resume" : "pause"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }
    }

    @objc private func testSound() { runPeon(["preview", "task.complete"]) }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        debugLog("menu: voz -> \(name)")
        runPeon(["packs", "use", name])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let px = sender.representedObject as? Int else { return }
        debugLog("menu: tamano -> \(px)px")
        resizePet(to: CGFloat(px))
        settingsModel.size = Double(px)
        rebuildMenu()
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PetMode(rawValue: raw) else { return }
        debugLog("menu: modo -> \(mode.rawValue)")
        PetPrefs.mode = mode
        settingsModel.mode = mode
        applyVisibility()
    }

    @objc private func toggleVisible() {
        petVisible.toggle()
        debugLog("menu: \(petVisible ? "mostrar" : "ocultar") orco")
        settingsModel.petVisible = petVisible
        applyVisibility()
    }

    @objc private func openSettings() {
        settingsModel.reload()
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView(model: settingsModel))
        host.preferredContentSize = NSSize(width: 460, height: 620)
        let w = NSWindow(contentViewController: host)
        w.title = "Ajustes de Peon Pet"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 460, height: 620))
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["PEONPET_SNAPSHOT"] != nil {
            // Self-portrait for verification: renders our own view, so it needs
            // no screen-recording permission.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    guard let view = w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/peonpet-settings.png"))
                        debugLog("snapshot escrito")
                    }
                }
            }
        }
        debugLog("ajustes abiertos: contenido \(Int(w.contentView?.frame.width ?? 0))x\(Int(w.contentView?.frame.height ?? 0)), packs=\(settingsModel.packs.count)")
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openEditor() {
        editorModel.load()
        if let w = editorWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SoundEditorView(model: editorModel))
        host.preferredContentSize = NSSize(width: 520, height: 600)
        let w = NSWindow(contentViewController: host)
        w.title = "Editar sonidos"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 520, height: 600))
        w.center()
        editorWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugLog("editor abierto: pack=\(editorModel.packName), eventos=\(editorModel.sounds.count)")

        if ProcessInfo.processInfo.environment["PEONPET_SNAPSHOT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    guard let view = w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/peonpet-editor.png"))
                        debugLog("snapshot editor escrito")
                    }
                }
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// Held in a global because NSApplication.delegate does not retain it.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar app: no dock clutter
    app.run()
}
