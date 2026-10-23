// ArasoBridge.dll (Swift: ArasoService over ArasoCore), loaded at run time from beside the exe,
// with the Swift runtime DLLs next to it. Called on the main thread only.
#pragma once

#include "../common/Common.h"
#include "../common/Json.h"

#include <initializer_list>
#include <string>

namespace araso {

class Bridge {
public:
    /// Loads the DLL and starts the runtime with the install's resources and the user's settings
    /// folder. False (with `error`) when the DLL or the Swift runtime is missing.
    bool Start(std::wstring &error);
    void WarmUp();
    bool started() const { return request_ != nullptr; }

    /// One request; the parsed answer (Null when the bridge isn't there).
    Json Request(const Json &request);
    /// The same, as text in and out (the pipe's requests go through untouched).
    std::string RequestText(const std::string &request);
    std::wstring Localize(const char *english);

    static Bridge &Shared();

    /// The install folder (where ArasoHost.exe is), its Resources folder, and %APPDATA%\Araso.
    static std::wstring ExeFolder();
    static std::wstring ResourcesFolder();
    static std::wstring SupportFolder();
    static std::string Version();

private:
    using StartFn = int (*)(const char *);
    using WarmUpFn = void (*)();
    using RequestFn = char *(*)(const char *);
    using LocalizeFn = char *(*)(const char *);
    using FreeFn = void (*)(char *);

    HMODULE module_ = nullptr;
    StartFn start_ = nullptr;
    WarmUpFn warmUp_ = nullptr;
    RequestFn request_ = nullptr;
    LocalizeFn localize_ = nullptr;
    FreeFn free_ = nullptr;
};

/// UI text in the user's language (Localizable.strings through the bridge); English is the key.
std::wstring L(const char *english);
/// `L` with `%@`/`%ld`/`%d` filled in order.
std::wstring L(const char *english, std::initializer_list<std::wstring> arguments);

}  // namespace araso
