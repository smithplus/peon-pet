# 🧌 PeonPet (nativo) — el orco de escritorio para Claude Code

Un pequeño orco de WarCraft que vive en el escritorio y reacciona a lo que hace **Claude Code**: escribe mientras hay una sesión trabajando, duerme cuando todo está quieto, festeja o se alarma según el evento, y muestra un puntito por cada chat activo. Es el "pet" visual que acompaña a **[peon-ping](https://github.com/PeonPing)** (que pone los sonidos).

App **nativa en Swift**, sin Xcode project ni Electron. Se compila con `./build.sh` (swiftc directo) y se instala en `~/Applications/PeonPet.app`.

## 🎯 Por qué existe / por qué nativo
Reemplaza al `peon-pet` original de Electron. Ganancia medida: de **4 procesos / 412 MB / ~4% de un core** a **1 proceso / 52 MB / ~0.08%**. El Electron viejo sigue clonado en `~/projects/personal/peon-pet` (sus LaunchAgents están `unload -w`).

## 🧰 Tech stack
| Capa | Qué se usa |
|---|---|
| Lenguaje | **Swift** (sin SPM/deps externas, sin Xcode project) |
| Build | **swiftc** vía `build.sh` → arma el `.app` a mano (Info.plist + recursos + binario) |
| Ventana / render | **AppKit** — `NSWindow` transparente always-on-top + `NSView` con **CALayer** (sprites en capas, animaciones en el render server = 0 CPU entre frames) |
| UI de ajustes/editor | **SwiftUI** embebido en `NSHostingController` |
| Watchers | **CoreServices/FSEvents** (transcripts) + **DispatchSource** (dir de `.state.json`) |
| Detección de Claude | **NSWorkspace** (app de escritorio) + **sysctl `KERN_PROC`** (CLI en terminal, lee la tabla de procesos del kernel — sin `ps`) |
| Login item | **ServiceManagement** (`setLaunchAtLogin`) |

## 🧩 Arquitectura / flujo de datos

```
ClaudeMonitor ──(¿Claude abierto?)──► main.applyVisibility()      # mostrar/ocultar según modo
   │  NSWorkspace (app) + sysctl (CLI, cada 15s)
   │
EventFeed ──► onEvent(Anim)      ──► PetView.play(anim)           # animación por evento de hook
   │  ├─ .state.json (DispatchSource sobre el DIR)                # evento + session_id
   │  └─ FSEvents sobre ~/.claude/projects  ──► onActivity()  ──► PetView.wakeIfSleeping()
   │                                          └─► onSessions() ──► PetView.setSessions()   # puntitos
   │
PetView (SpriteAnimator)                                          # typing si anySessionHot, si no sleeping
```

**Doble señal (la clave):** peon-ping reescribe `~/.claude/hooks/peon-ping/.state.json` en **cada hook** (empieza prompt, termina turno, error…), pero **entre hooks no escribe nada** → un turno largo dormiría al orco. Los transcripts `.jsonl` **se appendean continuamente**, así que su actividad (vía FSEvents) es la señal de "sigo trabajando". Cada `.jsonl` que cambia marca su sesión como *hot* (<30s), *warm* (<120s) o *stale* (>600s, se descarta). Por eso **contempla varios chats a la vez** (un puntito verde por sesión hot).

## 🎞️ Eventos → animaciones (`Sprite.Anim.forHookEvent`)
| Hook de peon-ping | Animación | Fila del atlas |
|---|---|---|
| `SessionStart` | `waking` | 1 |
| `UserPromptSubmit` | `typing` | 2 |
| `Stop` (turno termina) | `celebrate` | 4 |
| `PermissionRequest` / `Notification` / `PreCompact` | `alarmed` | 3 |
| `PostToolUseFailure` | `annoyed` | 5 |
| *(idle)* | `sleeping` | 0 |
> Los frames se **pre-cortan en build** (`Tools/slice.swift`) y se cargan lazy/cacheados: una sesión que nunca falla no paga por la fila `annoyed`.

## 🗂️ Mapa de código (`Sources/`)

| Archivo | Tipos | Funciones clave |
|---|---|---|
| **`main.swift`** | `AppDelegate` | `applicationDidFinishLaunching` (arranca ClaudeMonitor + EventFeed y cablea todo), `buildPetWindow`, `resizePet`, `applyVisibility`/`applyVisibilityIfModeChanged` (modo follow/always/off), `buildStatusItem`/`makeMenu` (menú de tray + dock). **Wiring:** `onEvent→play`, `onSessions→setSessions`, `onActivity→wakeIfSleeping`. |
| **`ClaudeMonitor.swift`** | `ClaudeMonitor` | `start` (observa `NSWorkspace` launch/terminate + timer 15s), `update` (`appRunning` vía NSWorkspace, `cliRunning` vía `sysctl KERN_PROC` filtrando procesos sin tty). Ignora `claude.exe` sin terminal (MCP servers del browser). Callbacks `onChange`/`onTick`. |
| **`EventFeed.swift`** | `EventFeed`, `Session` (hot/warm/stale) | `start`, `watch` (DispatchSource sobre el **dir** de `.state.json`), `readState` (parsea `last_active` → emite `onEvent`), `watchTranscripts` (FSEvents), `transcriptsChanged` (marca sesión hot → `onActivity`+`onSessions`), `pruneAndPublish` (descarta stale). |
| **`PetWindow.swift`** | `PetWindow` (NSWindow), `PetView` (NSView) | `setSessions` (guarda sesiones + calcula `anySessionHot`), `layoutDots` (puntitos verdes pulsando), `wakeIfSleeping`, `play`, `setActive` (frena la animación si el orco está oculto), `buildLayers`, drag/resize por las 4 esquinas (`corner`/`mouseDown`/`mouseDragged`). |
| **`Sprite.swift`** | `AnimSpec`, `Anim` (enum), `FrameStore`, `SpriteAnimator` | `Anim.forHookEvent` (mapeo de arriba), `FrameStore.image` (lazy+cache), `SpriteAnimator.play`/`tick`/`show`/`stop`, callback `onFinish` (regla idle). |
| **`Config.swift`** | `Paths`, `PetMode`, `PeonConfig`, `SoundPack`, `PetPrefs` | `runPeon` (wrapper del CLI `peon`), `readJSON`/`writeJSON`, `PeonConfig.load`/`setCategory`/`setDesktopNotifications`, `installedPacks`/`packsByLanguage`, `debugLog`. |
| **`SettingsWindow.swift`** | `SettingsModel` (ObservableObject), `SettingsView` (SwiftUI) | `reload`, `setLaunchAtLogin` (ServiceManagement), `categoryBinding` (toggles por evento), callbacks `onSize`/`onVisible`/`onOpenEditor`. |
| **`SoundEditor.swift`** | `EditableSound`, `SoundEditorModel`, `SoundEditorView` (SwiftUI) | `load`, `move` (pasar un sonido de un evento a otro), `play`, `save` (escribe solo `categories`, preserva el resto del manifiesto), `restore` (desde `.orig`), `selfTest`. |
| **`Tools/slice.swift`** | — | corta el atlas de sprites (ojo: `sips --cropOffset` mide desde el **centro**). |
| **`Tools/curate.py`** | — | arregla el defecto de sonido duplicado entre categorías en los packs instalados (`--restore` deshace). |

## 📁 Paths (dónde vive cada cosa) — `Config.Paths`
| Const | Ruta |
|---|---|
| `peonDir` / `peonConf` | `~/.claude/hooks/peon-ping/` · `.../config.json` |
| `.state.json` | `~/.claude/hooks/peon-ping/.state.json` *(lo que reescribe peon-ping)* |
| transcripts | `~/.claude/projects/**/<session>.jsonl` *(FSEvents observa el root)* |
| `openpeon` | `~/.openpeon/` (packs, `pet-mode`, `pet-native.json`) |
| `modeFile` | `~/.openpeon/pet-mode` → `follow` \| `always` \| `off` |
| CLI `peon` | `/opt/homebrew/bin/peon`, `/usr/local/bin/peon` o `~/.local/bin/peon` |

## 🔨 Build / instalar
```bash
./build.sh                                   # compila -> build/PeonPet.app
rm -rf ~/Applications/PeonPet.app
cp -R build/PeonPet.app ~/Applications/       # instalar
open ~/Applications/PeonPet.app               # correr
```

## 🐞 Debug
- `PEONPET_DEBUG=1` → traza cada evento por stderr:
  ```bash
  PEONPET_DEBUG=1 ~/Applications/PeonPet.app/Contents/MacOS/PeonPet 2>&1 \
    | grep -iE "sesiones|dormido|despierta|actividad|FSEvents|claude"
  ```
  Sano: `FSEvents sobre .../projects: started=true`, `FSEvents callback ... .jsonl`, `actividad en transcripts`, `sesiones: N (activas=…)`, `claude: app=… cli=…`.
- `PEONPET_OPEN_SETTINGS=1` / `PEONPET_OPEN_EDITOR=1` + `PEONPET_SNAPSHOT=1` → la app se autorretrata a `/tmp/peonpet-settings.png` (sin permiso de screen-recording).
- `PEONPET_WATCH_BUNDLE=<bundleid>` → probar el camino launch/terminate contra una app descartable en vez de cerrar Claude.

## ⚠️ Gotchas (cada uno costó una ronda de debugging)
- Observar el **directorio** de `.state.json`, nunca el fd: peon-ping reescribe atómico y cambia el inode.
- FSEvents necesita `kFSEventStreamCreateFlagUseCFTypes`; sin eso `eventPaths` es `char**` de C y leerlo como NSArray da basura.
- Detección de CLI por **sysctl**, no `pgrep -f`: Claude.app corre con hardened runtime (pgrep no lee sus args) y pgrep por nombre solo ve `Claude Helper`. Filtrar procesos sin tty (`e_tdev == -1`) para ignorar los `claude.exe` de fondo (MCP del browser).
- peon-ping **no** registra `PostToolUseFailure` en `last_active` → `annoyed` no dispara desde `.state.json`.
- `NSHostingController` cuyo root SwiftUI no tiene alto explícito abre como una barra de título pelada.
- `sips --cropOffset` mide desde el centro de la imagen → cortar el atlas con `Tools/slice.swift`.

## 🩹 Fix 2026-08-21 — el orco se quedaba dormido
**Síntoma:** el audio andaba (los hooks sonaban) pero **la imagen quedaba dormida** y no mostraba los puntitos de los varios chats.
**Causa:** `PetView.setSessions` (`PetWindow.swift`) **nunca guardaba** `sessions = next` y calculaba `anySessionHot` sobre el `sessions` viejo (siempre vacío) → `anySessionHot` siempre `false` → al terminar cada animación, `SpriteAnimator.onFinish` caía a `.sleeping`.
**Fix:** `sessions = next` + `anySessionHot = next.contains { $0.hot }`. Verificado con `PEONPET_DEBUG=1`: despierta con la actividad y cuenta múltiples sesiones hot.

## 🔜 Ideas / pendientes
- [ ] **Artículo simple para el blog personal** sobre el orco (historia Electron→Swift, ahorro de recursos, bugs de debugging).

> Curado de packs + editor de sonidos: ver [`plan.md`](plan.md). Contexto extendido y notas del Electron viejo: memoria del proyecto `peon-ping-setup` (Claude Code).
