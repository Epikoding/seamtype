// What the text service (ArasoTip.dll) and the host (ArasoHost.exe) share: names, the pipe,
// text conversions and logging. Never log typed text: the kind of key and the app only.
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <string>

namespace araso {

std::wstring Wide(const std::string &utf8);
std::string Utf8(const std::wstring &wide);
std::string Utf8(const wchar_t *wide, size_t length);

/// The host's pipe, one per user session: `\\.\pipe\Araso.<session>.<user>`.
std::wstring PipeName();

/// The window message the host posts to a text service's message-only window when it has edits
/// waiting for it (a click in the candidate window, a vim mode change), and the host's own
/// window class, which the settings window finds to say the files changed.
constexpr const wchar_t *kPendingMessage = L"Araso.Pending";
constexpr const wchar_t *kHostWindowClass = L"ArasoHostWindow";
constexpr const wchar_t *kSettingsWindowClass = L"ArasoSettingsWindow";
constexpr const wchar_t *kHostMutex = L"Local\\Araso.Host";

/// WM_COPYDATA kinds between the host and the settings window.
enum CopyDataKind : ULONG_PTR {
    kCopyReload = 1,       // settings window → host: the files changed (data: "kanjiReset" or empty)
    kCopyFilesChanged = 2, // host → settings window: the menu changed the files
    kCopyTrace = 3,        // host → settings window: how the word typed in Try Typing was decided (JSON)
    kCopyVim = 4,          // `--vim` → host: {"vim": mode, "app": exe}
};

/// One request/answer over a pipe in message mode, with a timeout so a hung host never hangs the
/// app being typed in. The handle must be opened with FILE_FLAG_OVERLAPPED.
bool Transact(HANDLE pipe, const std::string &request, std::string &answer, DWORD timeoutMs);

/// Reads one whole message (blocking, for the host's per-client threads).
bool ReadMessage(HANDLE pipe, std::string &message);
bool WriteMessage(HANDLE pipe, const std::string &message);

/// The exe name of this process, lowercase (`notepad.exe`): what apps.json names apps by.
std::wstring ProcessName();

void Log(const char *format, ...);

}  // namespace araso
