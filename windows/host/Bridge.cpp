#include "Bridge.h"

#include "araso_version.h"

#include <cstdio>
#include <vector>

#include <shlobj.h>

#include <map>

namespace araso {

Bridge &Bridge::Shared() {
    static Bridge bridge;
    return bridge;
}

std::wstring Bridge::ExeFolder() {
    wchar_t path[MAX_PATH] = L"";
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring folder = path;
    size_t slash = folder.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"." : folder.substr(0, slash);
}

std::wstring Bridge::ResourcesFolder() { return ExeFolder() + L"\\Resources"; }

std::wstring Bridge::SupportFolder() {
    PWSTR roaming = nullptr;
    std::wstring folder;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &roaming))) folder = roaming;
    CoTaskMemFree(roaming);
    return folder + L"\\Araso";
}

std::string Bridge::Version() { return ARASO_VERSION_STRING; }

bool Bridge::Start(std::wstring &error, bool converter) {
    if (request_) return true;
    std::wstring folder = ExeFolder();
    // The Swift runtime DLLs sit beside the bridge; look there first.
    SetDllDirectoryW(folder.c_str());
    module_ = LoadLibraryExW((folder + L"\\ArasoBridge.dll").c_str(), nullptr,
                             LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!module_) {
        error = L"ArasoBridge.dll could not be loaded (" + std::to_wstring(GetLastError()) + L")";
        return false;
    }
    start_ = reinterpret_cast<StartFn>(GetProcAddress(module_, "araso_start"));
    warmUp_ = reinterpret_cast<WarmUpFn>(GetProcAddress(module_, "araso_warm_up"));
    request_ = reinterpret_cast<RequestFn>(GetProcAddress(module_, "araso_request"));
    localize_ = reinterpret_cast<LocalizeFn>(GetProcAddress(module_, "araso_localize"));
    free_ = reinterpret_cast<FreeFn>(GetProcAddress(module_, "araso_free"));
    if (!start_ || !warmUp_ || !request_ || !localize_ || !free_) {
        error = L"ArasoBridge.dll is missing functions";
        request_ = nullptr;
        return false;
    }
    wchar_t locale[LOCALE_NAME_MAX_LENGTH] = L"en";
    LCIDToLocaleName(MAKELCID(GetUserDefaultUILanguage(), SORT_DEFAULT), locale, LOCALE_NAME_MAX_LENGTH, 0);
    Json config = Json::object();
    config.set("resources", Utf8(ResourcesFolder()));
    config.set("support", Utf8(SupportFolder()));
    config.set("version", Version());
    config.set("language", Utf8(locale));
    config.set("ownApp", Utf8(ProcessName()));
    config.set("converter", converter);
    if (start_(config.dump().c_str()) != 0) {
        error = L"ArasoBridge didn't start";
        request_ = nullptr;
        return false;
    }
    return true;
}

void Bridge::WarmUp() {
    if (warmUp_) warmUp_();
}

std::string Bridge::RequestText(const std::string &request) {
    if (!request_) return R"({"reply":{"handled":false,"ops":[]},"error":"no bridge"})";
    char *answer = request_(request.c_str());
    std::string out = answer ? answer : "";
    if (answer) free_(answer);
    return out;
}

Json Bridge::Request(const Json &request) {
    if (!request_) return Json();
    return Json::parse(RequestText(request.dump()));
}

std::wstring Bridge::Localize(const char *english) {
    if (!localize_) return Wide(english);
    static std::map<std::string, std::wstring> cache;
    auto found = cache.find(english);
    if (found != cache.end()) return found->second;
    char *text = localize_(english);
    std::wstring out = Wide(text ? text : english);
    if (text) free_(text);
    cache[english] = out;
    return out;
}

std::wstring L(const char *english) { return Bridge::Shared().Localize(english); }

std::wstring L(const char *english, std::initializer_list<std::wstring> arguments) {
    std::wstring format = L(english);
    std::wstring out;
    auto next = arguments.begin();
    for (size_t k = 0; k < format.size(); k++) {
        if (format[k] != L'%' || k + 1 >= format.size()) {
            out += format[k];
            continue;
        }
        const wchar_t *rest = format.c_str() + k + 1;
        size_t skip = 0;
        if (rest[0] == L'@' || rest[0] == L'd') skip = 1;
        else if (rest[0] == L'l' && (rest[1] == L'd' || rest[1] == L'u')) skip = 2;
        else if (rest[0] == L'%') { out += L'%'; k++; continue; }
        if (!skip) { out += L'%'; continue; }
        if (next != arguments.end()) out += *next++;
        k += skip;
    }
    return out;
}

}  // namespace araso
