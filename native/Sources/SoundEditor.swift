import AppKit
import SwiftUI

/// One sound as shown in the editor.
struct EditableSound: Identifiable, Hashable {
    let file: String
    let label: String
    var id: String { file }
}

/// Events in the order they matter to the user, with their Spanish names.
let EDITOR_CATEGORIES: [(key: String, label: String)] = [
    ("task.complete", "Terminé"),
    ("input.required", "Te necesito"),
    ("task.error", "Se rompió"),
    ("resource.limit", "Sin nafta"),
    ("session.start", "Al abrir sesión"),
    ("task.acknowledge", "Al arrancar tarea"),
    ("user.spam", "Si te apuro"),
]

@MainActor
final class SoundEditorModel: ObservableObject {
    @Published var packName: String = ""
    @Published var sounds: [String: [EditableSound]] = [:]
    @Published var dirty = false
    @Published var status = ""

    var packs: [SoundPack] = []
    private var player: NSSound?

    private var packDir: URL { Paths.packsDir.appending(path: packName) }
    private var manifestURL: URL { packDir.appending(path: "openpeon.json") }
    private var backupURL: URL { packDir.appending(path: "openpeon.json.orig") }

    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    func load(pack: String? = nil) {
        packs = installedPacks()
        packName = pack ?? PeonConfig.load().pack
        guard !packName.isEmpty else { return }
        let m = readJSON(manifestURL)
        var out: [String: [EditableSound]] = [:]
        let cats = m["categories"] as? [String: Any] ?? [:]
        for (key, value) in cats {
            let list = (value as? [String: Any])?["sounds"] as? [[String: Any]] ?? []
            out[key] = list.map {
                EditableSound(file: $0["file"] as? String ?? "",
                              label: $0["label"] as? String ?? ($0["file"] as? String ?? ""))
            }
        }
        sounds = out
        dirty = false
        status = ""
    }

    func move(_ sound: EditableSound, from: String, to: String) {
        guard from != to else { return }
        // A category with a single sound would go silent if emptied
        guard (sounds[from]?.count ?? 0) > 1 else {
            status = "«\(EDITOR_CATEGORIES.first { $0.key == from }?.label ?? from)» quedaría sin sonidos"
            return
        }
        sounds[from]?.removeAll { $0.file == sound.file }
        sounds[to, default: []].append(sound)
        dirty = true
        status = ""
    }

    func play(_ sound: EditableSound) {
        let url = packDir.appending(path: sound.file)
        player?.stop()
        let s = NSSound(contentsOf: url, byReference: true)
        s?.volume = Float(PeonConfig.load().volume)
        s?.play()
        player = s
    }

    /// Writes only the categories back, so anything else in the manifest
    /// (author, licence, checksums) survives untouched.
    func save() {
        var m = readJSON(manifestURL)
        guard !m.isEmpty else { return }
        if !hasBackup {
            try? FileManager.default.copyItem(at: manifestURL, to: backupURL)
        }
        var cats: [String: Any] = [:]
        for (key, list) in sounds where !list.isEmpty {
            cats[key] = ["sounds": list.map { ["file": $0.file, "label": $0.label] }]
        }
        m["categories"] = cats
        writeJSON(manifestURL, m)
        dirty = false
        status = "Guardado"
    }

    /// Drives move → save → restore without a human, and reports whether the
    /// manifest survived the round trip byte for byte.
    func selfTest() {
        load()   // must precede the read: packName is empty until it runs
        let before = (try? Data(contentsOf: manifestURL)) ?? Data()
        guard let source = EDITOR_CATEGORIES.first(where: { (sounds[$0.key]?.count ?? 0) > 1 }),
              let sound = sounds[source.key]?.first,
              let target = EDITOR_CATEGORIES.first(where: { $0.key != source.key })
        else { debugLog("autotest: pack sin material suficiente"); return }

        debugLog("autotest: muevo «\(sound.label)» de \(source.label) a \(target.label)")
        move(sound, from: source.key, to: target.key)
        debugLog("autotest: dirty=\(dirty)")
        save()

        let saved = readJSON(manifestURL)
        let cats = saved["categories"] as? [String: Any] ?? [:]
        let inTarget = ((cats[target.key] as? [String: Any])?["sounds"] as? [[String: Any]] ?? [])
            .contains { $0["file"] as? String == sound.file }
        let inSource = ((cats[source.key] as? [String: Any])?["sounds"] as? [[String: Any]] ?? [])
            .contains { $0["file"] as? String == sound.file }
        debugLog("autotest: guardado -> en destino=\(inTarget), sigue en origen=\(inSource)")
        debugLog("autotest: backup creado=\(hasBackup)")

        // Guard: a category with one sound must refuse to be emptied
        if let solo = EDITOR_CATEGORIES.first(where: { (sounds[$0.key]?.count ?? 0) == 1 }),
           let only = sounds[solo.key]?.first {
            status = ""
            move(only, from: solo.key, to: source.key)
            debugLog("autotest: mover el unico sonido de \(solo.label) -> bloqueado=\(!status.isEmpty)")
        }

        restore()
        let after = (try? Data(contentsOf: manifestURL)) ?? Data()
        debugLog("autotest: restaurado identico al original=\(before == after)")
        debugLog("autotest: backup eliminado=\(!hasBackup)")
    }

    func restore() {
        guard hasBackup else { return }
        try? FileManager.default.removeItem(at: manifestURL)
        try? FileManager.default.copyItem(at: backupURL, to: manifestURL)
        try? FileManager.default.removeItem(at: backupURL)
        load(pack: packName)
        status = "Restaurado al original"
    }
}

struct SoundEditorView: View {
    @ObservedObject var model: SoundEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack {
            Text("Pack").foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.packName },
                set: { model.load(pack: $0) })) {
                ForEach(packsByLanguage(), id: \.language) { group in
                    Section(languageLabel(group.language)) {
                        ForEach(group.packs, id: \.name) { p in
                            Text(p.label).tag(p.name)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            Spacer()
        }
        .padding(12)
    }

    private var list: some View {
        List {
            ForEach(EDITOR_CATEGORIES, id: \.key) { cat in
                Section(header: Text("\(cat.label)  ·  \(model.sounds[cat.key]?.count ?? 0)")) {
                    ForEach(model.sounds[cat.key] ?? []) { sound in
                        row(sound, in: cat.key)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ sound: EditableSound, in category: String) -> some View {
        HStack(spacing: 8) {
            Button {
                model.play(sound)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Escuchar")

            Text(sound.label)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Menu {
                ForEach(EDITOR_CATEGORIES.filter { $0.key != category }, id: \.key) { target in
                    Button(target.label) {
                        model.move(sound, from: category, to: target.key)
                    }
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Mover a otro evento")
        }
    }

    private var footer: some View {
        HStack {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(model.status.contains("quedaría") ? .orange : .secondary)
            Spacer()
            if model.hasBackup {
                Button("Restaurar original") { model.restore() }
            }
            Button("Guardar") { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty)
        }
        .padding(12)
    }
}
