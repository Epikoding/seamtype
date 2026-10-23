// ArasoHost.exe, what the Araso app is on macOS (main.swift):
//   --server                     the input method's host (the default; started at sign-in)
//   --settings [tab]             the settings window: general, keys, apps, typing, learning, about
//   --vim insert|normal|off [--app <exe>]   vim's mode (scripts/vim), passed to the host
//   --register | --unregister    turn the input method on or off for this user (the installer)
//   --selftest                   load every model through the bridge and exit 0 when all work
#include "../common/Common.h"
#include "Bridge.h"
#include "Server.h"
#include "Settings.h"

#include <commctrl.h>
#include <objbase.h>
#include <objidl.h>
#include <gdiplus.h>
#include <shellapi.h>

#include <string>
#include <vector>

using namespace araso;

namespace {

std::vector<std::wstring> Arguments() {
    int count = 0;
    LPWSTR *list = CommandLineToArgvW(GetCommandLineW(), &count);
    std::vector<std::wstring> out;
    for (int k = 1; k < count; k++) out.push_back(list[k]);
    LocalFree(list);
    return out;
}

std::wstring After(const std::vector<std::wstring> &args, const wchar_t *flag) {
    for (size_t k = 0; k + 1 < args.size(); k++) {
        if (args[k] == flag) return args[k + 1];
    }
    return L"";
}

bool Has(const std::vector<std::wstring> &args, const wchar_t *flag) {
    for (const auto &arg : args) if (arg == flag) return true;
    return false;
}

/// Vim's mode change: handed to the host, which tells the text field's session.
int Vim(const std::vector<std::wstring> &args) {
    std::wstring mode = After(args, L"--vim");
    if (mode != L"insert" && mode != L"normal" && mode != L"off") return 2;
    Json signal = Json::object();
    signal.set("vim", Utf8(mode));
    std::wstring app = After(args, L"--app");
    if (!app.empty()) {
        CharLowerBuffW(app.data(), static_cast<DWORD>(app.size()));
        signal.set("app", Utf8(app));
    }
    HWND host = FindWindowW(kHostWindowClass, nullptr);
    if (!host) return 1;
    std::string data = signal.dump();
    COPYDATASTRUCT copy = {kCopyVim, static_cast<DWORD>(data.size()), data.data()};
    SendMessageTimeoutW(host, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&copy), SMTO_ABORTIFHUNG, 1000, nullptr);
    return 0;
}

/// Adds Araso to (or takes it off) this user's input methods: what the user does in Settings →
/// Time & language → Language → Korean → Keyboards. The installer runs it as the user.
int Register(bool add) {
    using InstallFn = BOOL(WINAPI *)(LPCWSTR, DWORD);
    HMODULE input = LoadLibraryW(L"input.dll");
    auto install = input ? reinterpret_cast<InstallFn>(GetProcAddress(input, "InstallLayoutOrTip")) : nullptr;
    if (!install) return 1;
    // 0412 (Korean), the text service's CLSID and its profile (windows/tip/Tsf.h).
    const wchar_t *profile = L"0412:{6D6C7D5F-3B7F-4F0E-9A2C-417261736F01}{6D6C7D5F-3B7F-4F0E-9A2C-417261736F02}";
    BOOL ok = install(profile, add ? 0 : 1 /* ILOT_UNINSTALL */);
    FreeLibrary(input);
    return ok ? 0 : 1;
}

/// Every model loads from the install and decides as it should (for the installer's build).
int SelfTest() {
    std::wstring error;
    if (!Bridge::Shared().Start(error)) {
        Log("selftest: %s", Utf8(error).c_str());
        return 1;
    }
    auto decide = [](const char *keys) {
        Json request = Json::object();
        request.set("op", "decide");
        request.set("keys", keys);
        return Bridge::Shared().Request(request)["decision"];
    };
    bool english = decide("hello")["language"].asString() == "english";
    bool korean = decide("dkssud")["output"].asString() == "안녕";
    Json readings = Json::object();
    readings.set("op", "readings");
    readings.set("keys", "rk");
    bool strings = !L("Araso Settings…").empty();
    bool choices = Bridge::Shared().Request(readings)["choices"].size() >= 2;
    bool ok = english && korean && strings && choices;
    Log("selftest: english %d korean %d readings %d", english, korean, choices);
    // A console started it (the build): say so there too.
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
        DWORD written = 0;
        const char *line = ok ? "selftest: ok\r\n" : "selftest: FAILED\r\n";
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line, static_cast<DWORD>(strlen(line)), &written, nullptr);
    }
    return ok ? 0 : 1;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    std::vector<std::wstring> args = Arguments();
    if (Has(args, L"--vim")) return Vim(args);
    if (Has(args, L"--register")) return Register(true);
    if (Has(args, L"--unregister")) return Register(false);

    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX controls = {sizeof controls, ICC_STANDARD_CLASSES | ICC_LISTVIEW_CLASSES | ICC_TAB_CLASSES |
                                                       ICC_LINK_CLASS | ICC_BAR_CLASSES};
    InitCommonControlsEx(&controls);
    ULONG_PTR gdiplus = 0;
    Gdiplus::GdiplusStartupInput startup;
    Gdiplus::GdiplusStartup(&gdiplus, &startup, nullptr);

    int result;
    if (Has(args, L"--selftest")) {
        result = SelfTest();
    } else if (Has(args, L"--settings")) {
        std::wstring tab = After(args, L"--settings");
        result = RunSettings(tab.empty() || tab.rfind(L"--", 0) == 0 ? "general" : Utf8(tab));
    } else {
        Server server;
        result = server.Run();
    }
    Gdiplus::GdiplusShutdown(gdiplus);
    CoUninitialize();
    return result;
}
