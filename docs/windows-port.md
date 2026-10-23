# Araso for Windows

Araso on Windows is the same input method: `ArasoCore` (every decision, the dictionary, kana and
kanji) is shared as is, and only the layer that macOS's InputMethodKit gave is new. This file maps
each macOS piece to its Windows one and says where the two differ.

## Shape

```
 every app that types                         one per user session
┌──────────────────────────────┐   named pipe   ┌──────────────────────────────────────────┐
│ ArasoTip.dll (C++, TSF)      │ ─────────────> │ ArasoHost.exe --server (C++)              │
│  key sink, composition,      │  JSON request  │  ArasoBridge.dll (Swift: ArasoService     │
│  display attributes, the     │ <───────────── │   over ArasoCore) does every decision     │
│  language bar button         │  ops + UI      │  candidate window, readings list,         │
│  x64, x86, ARM64 builds      │                │  correction pill, pause HUD, updates      │
└──────────────────────────────┘                └──────────────────────────────────────────┘
                                                 ArasoHost.exe --settings <tab>  (own process)
                                                 ArasoHost.exe --vim <mode> --app <exe>
```

- **Why a host process and not the Swift core in every app.** On macOS one Araso process serves
  every app; learning writes `dictionary.json` from that one process. Loaded into every app, the
  core would write the dictionary from many processes at once, load the models (and the 35 MB
  kanji dictionary) once per app, and need the Swift runtime in 32-bit and sandboxed apps. The
  TSF DLL stays small C++ with no Swift in it, so it builds for x86 and ARM64 too.
- **The text field is snapshotted.** `InputSession` talks to a `TextClient` that it may ask for
  the selection, the marked range and text before the caret. The DLL sends those with each key
  (`ServiceRequest.Context`: the selection and composition as ACP offsets, up to 64 UTF-16 units
  before the caret); `SnapshotClient` (ArasoService) answers from them, applies each edit to its
  copy and records it; the DLL applies the recorded edits in its edit session in order.
- **What only the host can start** (a click in the candidate window, a vim mode change that
  commits, a settings change) is queued per client; the host posts `WM_ARASO_PENDING` to the
  DLL's message-only window, and the DLL fetches and applies the edits in an edit session.

## macOS → Windows

| macOS | Windows | Notes |
| --- | --- | --- |
| IMKInputController, `handle(_:client:)` | `ITfKeyEventSink` (`TextService.cpp`) | Every key but bare modifiers goes to the host; `OnTestKeyDown` says it may be eaten, `OnKeyDown` returns the session's answer, so a key the session passes reaches the app (Space after a word, as on macOS). |
| `IMKClient` (`TextClient`) | `SnapshotClient` + edit sessions | Ranges are UTF-16 offsets in both (NSRange ↔ ACP). |
| marked text, clause underlines | TSF composition + `ITfDisplayAttributeProvider` | Input: dotted underline; converted clause: thin; selected clause: thick. |
| `IMKCandidates` | host's candidate window (`CandidateWindow.cpp`) | Same rows, highlight, keys; also takes a click. |
| `ReadingsHUD`, `LearnedHUD`, `PauseHUD` (CaretPanel, PauseHUD) | host's `ReadingsWindow`, `LearnedPill`, `PauseHud` | Positioned from `ITfContextView::GetTextExt` of the composition / caret. |
| input menu (`menu()`) | language bar button menu (`ITfLangBarItemButton`) | The same items, built by `ServiceRuntime.menu` in Swift, so both read alike. |
| bundle identifier (`apps.json`) | exe name, lowercase (`notepad.exe`, `code.exe`) | A key ending in `.` still matches as a prefix. |
| right ⌥ tap (switch key) | right Alt tap, or the 한/영 key | On Korean keyboards the right Alt key is 한/영 (`VK_HANGUL`). An AltGr layout sends left Ctrl with right Alt; a tap is still one press and release with no other key. |
| right ⇧ tap | right Shift tap | |
| ⌥Space | Alt+Space | Taken only when chosen (it opens the window menu otherwise). |
| Esc, ⇧Esc | Esc, Shift+Esc | |
| pause: right ⌘ tap (default) | right Ctrl tap (default), or the 한자 key | A lone Windows key opens Start, so it can't be a tap. `rightCommand` in settings.json means right Win on Windows, still allowed in the file. |
| pause shortcut (⌃⌥P) | Ctrl/Alt/Win + key | Stored with macOS key codes and names in settings.json on both, so the file is the same; `KeyMapper` maps scan codes to them. |
| ⌘ going down commits a held word | Ctrl going down | Windows pastes with Ctrl+V. |
| ⌃J/⌃K, F6/F7 | F6/F7, and Ctrl+U/Ctrl+I while a word is underlined | Ctrl+J/K are common app shortcuts on Windows; Ctrl+U/I are MS-IME's. |
| Secure Event Input (`MaskedField`) | the field's input scope (`IS_PASSWORD`, `IS_PRIVATE`) | Keys go to the app as typed. |
| `Araso --vim` (distributed notification) | `ArasoHost.exe --vim … --app <exe>` (named pipe) | `scripts/vim` picks the exe and `GetModuleFileName` of the terminal isn't known to vim, so `--app` is the terminal's exe name from `$ARASO_APP` or `wezterm-gui.exe`/`windowsterminal.exe` guessed by the script; without it the signal is taken where Esc isn't a switch key, as on macOS. |
| text replacements (System Settings) | `replacements.json` in the settings folder | Windows has no system list. Apps don't replace on Windows, so Araso replaces a shortcut itself when Space or a symbol ends it. |
| macOS Japanese engine (`japaneseEngine: "apple"`) | AzooKey | `AppleJapaneseConverter` returns nil off macOS; `"apple"` falls back to AzooKey as it already did. |
| `~/Library/Application Support/Araso` | `%APPDATA%\Araso` | Foundation's application support folder. Same files and format. |
| Settings window (SwiftUI) | `ArasoHost.exe --settings <tab>` (Win32) | Same panes: Languages, Keys, Apps, Dictionary, Try Typing, About. Files written through ArasoBridge, so the JSON is the same. |
| settings-changed distributed notification | pipe message `reload` → host; host → open settings window: `WM_COPYDATA` | |
| Updater (pkg, `pkgutil --check-signature`) | `Araso-Setup.exe` from the same GitHub release, Authenticode check (`WinVerifyTrust`) | `Release.swift` parses the release in Swift for both. |
| pkg / get.sh, Registration | Inno Setup installer (`windows/installer/Araso.iss`), `regsvr32` of both DLLs, `ArasoHost.exe --register` (`InstallLayoutOrTip`) | Uninstall from Apps & features or About. |
| `Localizable.strings` | the same `ko.lproj/Localizable.strings`, read by the host | Korean when the Windows UI language is Korean. |
| `os.Logger` | `OutputDebugString` (keys' kinds and the app only, never text) | |

## Not on Windows

- `scripts/typing-test`, `scripts/record-demo`: macOS automation.
- The input source switch indicator by the caret is Windows' own; the pause HUD draws Araso's icon.
- UI-less mode for full-screen games (`ITfUIElement`) isn't implemented: the candidate window is a
  topmost window, which an exclusive full-screen game may hide.

## Building

- Swift (the core and the bridge): `swift build -c release --product ArasoBridge` on Windows
  with the Swift toolchain (6.2 or later). `swift test` runs the same tests as on macOS.
- C++: `cmake -S windows -B build/windows -A x64 && cmake --build build/windows --config Release`
  (also `-A Win32` and `-A ARM64` for the TSF DLL). `windows/scripts/check-cross.sh` compiles the
  C++ on macOS or Linux with `zig c++ -target x86_64-windows-gnu`, to catch errors before CI.
- `.github/workflows/windows.yml` builds and tests both on `windows-latest` and leaves
  `Araso-Setup.exe` as an artifact.
