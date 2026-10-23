// The settings window's shared state and layout helpers (SettingsWindow.cpp), used by the panes
// (SettingsPanes.cpp). Controls are laid out top to bottom with `State::y`, rebuilt after each change.
#pragma once

#include "../common/Common.h"
#include "../common/Json.h"
#include "Bridge.h"

#include <commctrl.h>

#include <functional>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace araso {
namespace settings {

struct State {
    HWND frame = nullptr;
    HWND sidebar = nullptr;
    HWND content = nullptr;
    UINT dpi = 96;
    HFONT font = nullptr, bold = nullptr, fine = nullptr, title = nullptr;
    int pane = 0;
    Json model;
    int nextId = 1000;
    std::map<int, std::function<void(HWND, int)>> commands;
    std::map<int, std::function<void(NMHDR *)>> notifies;
    std::set<HWND> notes;
    int y = 0;
    int width = 0;

    // Apps
    std::string selectedApp;
    // Dictionary
    int filter = 0;
    std::wstring search;
    HWND wordList = nullptr;
    std::vector<Json> shownWords;
    // Try Typing
    std::vector<Json> traces;
    HWND traceList = nullptr;
    // About
    std::wstring updateStatus;
    bool busy = false;
};

extern State g;

/// The switch keys, in settings.json's order, with their names and notes on Windows.
struct SwitchKeyInfo {
    const char *id;
    const char *name;
    const char *note;
};
extern const SwitchKeyInfo kSwitchKeys[5];

constexpr UINT kRebuild = WM_APP + 10;
constexpr UINT kReleaseChecked = WM_APP + 11;
constexpr UINT kDownloaded = WM_APP + 12;

int S(int value);
Json Request(Json request);
void LoadModel();
void Rebuild();
void ShowPane(int pane);
/// Writes a change through the bridge, then the host and this window catch up.
void Apply(Json change, bool kanjiReset = false);
void ChangeSettings(const std::function<void(Json &)> &edit);
void ChangeDefault(const std::function<void(Json &)> &edit);
Json AppEntry(const std::string &app);
void ChangeApp(const std::string &app, const std::function<void(Json &)> &edit);
bool HasKey(const Json &keys, const std::string &id);
Json WithKey(const Json &keys, const std::string &id, bool on);
std::wstring KeyNames(const Json &keys);

// Layout
int Pad();
int ContentWidth();
HWND Make(const wchar_t *cls, const std::wstring &text, DWORD style, int x, int y, int w, int h, HFONT font,
          std::function<void(HWND, int)> command = nullptr);
void Title(const std::wstring &text, const std::wstring &note);
void Heading(const std::wstring &text);
void Note(const std::wstring &text, int indent = 0);
HWND Check(const std::wstring &text, bool on, bool enabled, std::function<void(bool)> changed, int indent = 0);
HWND Combo(const std::wstring &label, const std::vector<std::wstring> &items, int selected, bool enabled,
           std::function<void(int)> changed, int indent = 0);
HWND Push(const std::wstring &text, int x, int width, std::function<void()> clicked, bool enabled = true);
HWND List(const std::vector<std::pair<std::wstring, int>> &columns, int height);
void Row(HWND list, int row, const std::vector<std::wstring> &cells);
int Selected(HWND list);
bool Confirm(const std::wstring &question, const std::wstring &detail);
/// Keeps input methods (Araso itself) away from a control: it gets the keys as typed.
void WithoutInputMethod(HWND control);

/// A small modal window, run until it closes; the settings window waits under it.
class Dialog {
public:
    Dialog(const std::wstring &title, int width, int height);
    HWND window() const { return window_; }
    HWND Add(const wchar_t *cls, const std::wstring &text, DWORD style, int x, int y, int w, int h,
             std::function<void(HWND, int)> command = nullptr, HFONT font = nullptr);
    /// Keys pressed in `control` go to `handler` first; it returns true when it took the key.
    void TakeKeys(HWND control, std::function<bool(WPARAM, LPARAM)> handler);
    /// Runs until `Close`; true when closed with `Close(true)`.
    bool Run();
    void Close(bool accepted);

private:
    HWND window_ = nullptr;
    int next_ = 100;
    bool done_ = false;
    bool accepted_ = false;
    HWND keysControl_ = nullptr;
    std::function<bool(WPARAM, LPARAM)> keys_;
    std::map<int, std::function<void(HWND, int)>> commands_;

    static LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
};

// The panes (SettingsPanes.cpp).
void BuildLanguages();
void BuildKeys();
void BuildApps();
void BuildDictionary();
void BuildTyping();
void BuildAbout();
/// A trace from the host (Try Typing).
void AddTrace(const Json &trace);
/// The latest release check, done on a worker thread (About).
void CheckForUpdates();
void ReleaseChecked(std::string *body);
void Downloaded(std::wstring *path);
/// The dictionary's add/edit window, with `keys` filled in (Try Typing's Add to Dictionary).
void EditWord(const Json *word, const std::string &keys);

}  // namespace settings
}  // namespace araso
