# Araso for Windows

Araso on Windows is the same input method: `ArasoCore` (every decision, the dictionary, kana and
kanji) is shared as is, and only the layer that macOS's InputMethodKit and the Araso app gave is
new. This file maps each macOS piece to its Windows one and says where the two differ.

## Shape

```
 every app that types                          one per user session
┌───────────────────────────────┐  named pipe  ┌──────────────────────────────────────────┐
│ ArasoTip.dll (C++, TSF)       │ ───────────> │ ArasoHost.exe --server (C++)             │
│  key sink, composition,       │ JSON request │  ArasoBridge.dll (Swift: ArasoService    │
│  display attributes, the      │ <─────────── │   over ArasoCore) makes every decision   │
│  input indicator's menu       │  edits + UI  │  candidate window, pause indicator,      │
│  x64, x86 and ARM64 builds    │              │  daily update check                      │
└───────────────────────────────┘              └──────────────────────────────────────────┘
                                                ArasoHost.exe --settings <tab>  (own process)
                                                ArasoHost.exe --vim <mode> --app <exe>
```

- **Why a host process and not the Swift core in every app.** On macOS one Araso process serves
  every app, and learning writes `dictionary.json` from that one process. Loaded into every app,
  the core would write the dictionary from many processes at once, load the models (and the 35 MB
  kanji dictionary) once per app, and need the Swift runtime in 32-bit and sandboxed apps. The
  TSF DLL stays small C++ with no Swift in it, so it builds for x86 and ARM64 too.
- **The text field is snapshotted.** `InputSession` talks to a `TextClient` that it may ask for
  the selection, the marked range and text before the caret. The DLL sends those with each key
  (`TextContext`: the selection and composition as ACP offsets, and the text from 256 UTF-16 units
  before them); `SnapshotClient` answers from it, applies each edit to its copy and records it with
  the range it replaces; the DLL makes the recorded edits in its edit session, in order.
  `Tests/ArasoServiceTests` drive the runtime the same way (`FakeDocument`).
- **What only the host can start** (a click in the candidate window, a vim mode change that
  commits, the menu's Pause) is queued for the client; the host posts `Araso.Pending` to the DLL's
  message-only window, and the DLL fetches and makes those edits in an edit session.
- **Shortcuts stay the app's.** A key with Ctrl, Alt or Win is first offered to the host (`test`):
  only the pause shortcut, a switch key, or a word in progress (which goes in first) is taken in
  `OnTestKeyDown`; the rest reach the app untouched, and the session only hears of them.

## macOS → Windows

| macOS | Windows | Notes |
| --- | --- | --- |
| IMKInputController, `handle(_:client:)` | `ITfKeyEventSink` (`windows/tip/TextService.cpp`) | Keys go to the host; a key the session doesn't take still reaches the app (Space after a word, as on macOS). |
| `IMKClient` (`TextClient`) | `SnapshotClient` + edit sessions | UTF-16 offsets in both (NSRange ↔ ACP). A field without ACP positions still works, without the features that read back (a switch right after a commit, URLs). |
| marked text | TSF composition + `ITfDisplayAttributeProvider` | Underlined, as macOS draws marked text; a phrase being converted to kanji is drawn as the converted clause (thick). |
| `IMKCandidates` | the host's candidate window (`windows/host/Ui.cpp`) | Numbered rows, the highlight moving with Space/↓/↑; a click chooses. |
| `PauseHUD` | the host's `PauseHud` | Araso's icon under the caret for a moment, struck through when paused. |
| input menu (`menu()`) | the input indicator's menu (`LangBarButton`, `GUID_LBI_INPUTMODE`) | The same items and names, built by `ServiceRuntime.menu`. |
| bundle identifier (`apps.json`) | exe name, lowercase (`notepad.exe`, `code.exe`) | A key ending in `.` still matches as a prefix. |
| right ⌥ tap (switch key) | right Alt tap, or the 한/영 key | On Korean keyboards right Alt is 한/영 (`VK_HANGUL`). A lone right Alt's release is taken, so the app doesn't open its menu bar. |
| right ⇧ tap, ⌥Space, Esc, ⇧Esc | right Shift tap, Alt+Space, Esc, Shift+Esc | Alt+Space is taken only when chosen. |
| ⌘ | Ctrl (the shortcut key) | Right Ctrl tapped alone pauses (`rightCommand`, the default), and Ctrl going down puts a held word in before a paste. The 한자 key is right Ctrl. The Windows key plays ⌃ (`rightControl`). |
| pause shortcut (⌃⌥P) | Ctrl/Alt/Win + key | settings.json keeps macOS key codes and modifier names on both, so the file is the same; `KeyMapper` maps scan codes to them. |
| ⌃J/⌃K, F6/F7 | F6/F7 | Ctrl+J/K are app shortcuts on Windows. |
| letters and symbols | from the key's scan code, as on a US keyboard | As macOS has Araso type on the US layout, whatever layout Windows has. |
| Secure Event Input (`MaskedField`) | the field's input scope (`IS_PASSWORD`) | Keys go to the app as typed. |
| `Araso --vim` (distributed notification) | `ArasoHost.exe --vim … --app <exe>` (`WM_COPYDATA` to the host) | `scripts/vim` finds ArasoHost.exe; the app is `$ARASO_APP`, or the terminal guessed from `WT_SESSION`/`TERM_PROGRAM`. |
| text replacements (System Settings) | `replacements.json` in the settings folder | Windows has no system list. Apps don't replace on Windows, so Araso puts the phrase in itself when Space or a symbol ends a shortcut. |
| macOS Japanese engine (`japaneseEngine: "apple"`) | AzooKey | `AppleJapaneseConverter` returns nil off macOS; `"apple"` falls back to AzooKey as it already did. |
| `/usr/share/dict/words` (English letter trigrams) | `Data/english_spelling.txt` | The same web2 list (public domain), shipped: without it English scored differently. |
| `~/Library/Application Support/Araso` | `%APPDATA%\Araso` | Same files and format. |
| Settings window (SwiftUI) | `ArasoHost.exe --settings <tab>` (Win32) | Languages, Keys, Apps, Dictionary, Try Typing, About. Files are written through ArasoBridge, so the JSON is the same. |
| settings-changed notifications | `WM_COPYDATA` both ways (`kCopyReload`, `kCopyFilesChanged`) | Try Typing's traces come from the text service in the settings window's own process. |
| Updater (pkg, `pkgutil --check-signature`) | `Araso-Setup.exe` from the same GitHub release, Authenticode check of the publisher (`WinVerifyTrust`) | A build without a signing identity opens the release page instead. `ARASO_UPDATE_FEED` points the check at a file, as `updateFeed` does on macOS. |
| pkg, Registration, Uninstaller | Inno Setup (`windows/installer/Araso.iss`): regsvr32 of each DLL, `ArasoHost.exe --register` (`InstallLayoutOrTip`), the host in HKLM `Run` | Uninstall from Settings → Apps or About; the uninstaller asks whether to delete `%APPDATA%\Araso`. |
| `Localizable.strings` | the same file, plus `windows/Resources/ko.lproj/Windows.strings`, read by `Strings` (ArasoService) | Korean when Windows' display language is Korean. |
| `os.Logger` | `OutputDebugString` | The kind of key and the app only, never text. |

## Not on Windows

- The readings list, the correction marks and "Changed by the Dictionary" aren't on main yet;
  they come when the macOS branch that has them is merged (`UIState` is where they'd go).
- `scripts/typing-test`, `scripts/record-demo`: macOS automation.
- UI-less mode for full-screen games (`ITfUIElement`): the candidate window is a topmost window,
  which an exclusive full-screen game may hide.
- Untested on real hardware so far: the right Alt tap (TSF may not hand a lone Alt to the key
  sink in every app; 한/영 works where it doesn't), ARM64 registration, and Store (AppContainer)
  apps reaching the pipe.

## Building

- Swift: `swift build -c release --product ArasoBridge` on Windows with Swift 6.4 or later
  (6.2.0's optimizer crashed on a dependency). `swift test` runs the same tests as on macOS.
- C++: `cmake -S windows -B build/windows -A x64 && cmake --build build/windows --config Release`
  (also `-A Win32` for the text service and `-A ARM64`). `windows/scripts/check-cross.sh` compiles
  and links it on macOS or Linux with `zig c++`, to catch errors before CI.
- `.github/workflows/windows.yml` builds and tests both on `windows-latest`, stages them with the
  Swift and Visual C++ runtimes and the data, runs `ArasoHost.exe --selftest`, and leaves
  `Araso-Setup.exe` as an artifact.
- The icons: `swift windows/scripts/make-icon.swift [--slash] windows/Resources/Araso.ico`.
