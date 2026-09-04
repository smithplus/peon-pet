import SwiftUI
import ServiceManagement

@MainActor
final class SettingsModel: ObservableObject {
    @Published var mode: PetMode = .follow
    @Published var launchAtLogin = false
    @Published var paused = false
    @Published var pack = ""
    @Published var volume = 0.5
    @Published var desktopNotifications = true
    @Published var categories: [String: Bool] = [:]
    @Published var size: Double = 200
    @Published var petVisible = true

    var packs: [SoundPack] = []
    var groups: [(language: String, packs: [SoundPack])] = []
    var onSize: ((CGFloat) -> Void)?
    var onVisible: ((Bool) -> Void)?
    var onOpenEditor: (() -> Void)?

    func reload() {
        let cfg = PeonConfig.load()
        mode = PetPrefs.mode
        paused = PeonConfig.isPaused
        pack = cfg.pack
        volume = cfg.volume
        desktopNotifications = cfg.desktopNotifications
        categories = cfg.categories
        packs = installedPacks()
        groups = packsByLanguage()
        size = Double(PetPrefs.size)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("launch at login failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private let CATEGORY_LABELS: [(String, String)] = [
    ("task.complete", "Terminé"),
    ("input.required", "Te necesito"),
    ("task.error", "Se rompió"),
    ("resource.limit", "Sin nafta"),
    ("session.start", "Al abrir sesión"),
    ("task.acknowledge", "Al arrancar tarea"),
    ("user.spam", "Si te apuro"),
]

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    // Split into one computed property per section: a single large `body`
    // overwhelms the SwiftUI type checker.
    var body: some View {
        Form {
            behaviorSection
            soundSection
            categoriesSection
            appearanceSection
        }
        .formStyle(.grouped)
        // NSHostingController sizes itself from the SwiftUI content: without an
        // explicit height the window opens as a bare title bar.
        .frame(width: 460, height: 620)
        .onAppear { model.reload() }
    }

    private var behaviorSection: some View {
        Section("Comportamiento") {
            Picker("Cuándo se muestra", selection: $model.mode) {
                Text("Seguir a Claude").tag(PetMode.follow)
                Text("Siempre encendido").tag(PetMode.always)
                Text("Apagado").tag(PetMode.off)
            }
            .onChange(of: model.mode) { _, newValue in
                PetPrefs.mode = newValue
                NotificationCenter.default.post(name: .petModeChanged, object: nil)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            Toggle("Iniciar al abrir sesión", isOn: launchBinding)
        }
    }

    private var soundSection: some View {
        Section("Sonido") {
            Toggle("Sonidos en pausa", isOn: pausedBinding)
            Picker("Voz", selection: packBinding) {
                ForEach(model.groups, id: \.language) { group in
                    Section(languageLabel(group.language)) {
                        ForEach(group.packs, id: \.name) { p in
                            Text(p.label).tag(p.name)
                        }
                    }
                }
            }
            volumeRow
            Toggle("Avisos de escritorio", isOn: notifBinding)
            Button("Reproducir «Terminé»") { runPeon(["preview", "task.complete"]) }
            Button("Editar sonidos…") { model.onOpenEditor?() }
        }
    }

    private var volumeRow: some View {
        HStack {
            Text("Volumen")
            Slider(value: $model.volume, in: 0...1, step: 0.05) { editing in
                if !editing { runPeon(["volume", String(format: "%.2f", model.volume)]) }
            }
            Text("\(Int(model.volume * 100))%")
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var categoriesSection: some View {
        Section("Cuándo hablar") {
            ForEach(CATEGORY_LABELS, id: \.0) { pair in
                Toggle(pair.1, isOn: categoryBinding(pair.0))
            }
        }
    }

    private var appearanceSection: some View {
        Section("Apariencia") {
            HStack {
                Text("Tamaño del orco")
                Slider(value: $model.size, in: 120...420, step: 10)
                    .onChange(of: model.size) { _, v in model.onSize?(CGFloat(v)) }
                Text("\(Int(model.size))px")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Text("También se arrastra desde las esquinas")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Mostrar el orco", isOn: visibleBinding)
        }
    }

    // MARK: - Bindings that write through to peon-ping

    private var launchBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
    }

    private var pausedBinding: Binding<Bool> {
        Binding(get: { model.paused },
                set: { on in runPeon([on ? "pause" : "resume"]); model.paused = on })
    }

    private var packBinding: Binding<String> {
        Binding(get: { model.pack },
                set: { name in runPeon(["packs", "use", name]); model.pack = name })
    }

    private var notifBinding: Binding<Bool> {
        Binding(get: { model.desktopNotifications },
                set: { on in PeonConfig.setDesktopNotifications(on); model.desktopNotifications = on })
    }

    private var visibleBinding: Binding<Bool> {
        Binding(get: { model.petVisible },
                set: { on in model.petVisible = on; model.onVisible?(on) })
    }

    private func categoryBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { model.categories[key] == true },
                set: { on in PeonConfig.setCategory(key, on); model.categories[key] = on })
    }

    private var hint: String {
        switch model.mode {
        case .follow: return "Aparece con Claude y se cierra con Claude"
        case .always: return "Se queda en pantalla aunque cierres Claude"
        case .off:    return "No se muestra hasta que lo vuelvas a encender"
        }
    }
}

extension Notification.Name {
    static let petModeChanged = Notification.Name("petModeChanged")
}
