#include "Updater.h"

#include <softpub.h>
#include <wincrypt.h>
#include <winhttp.h>
#include <wintrust.h>

#include <vector>

namespace araso {

namespace updater {

namespace {

/// Splits an https URL and opens a request for it; follows GitHub's redirects to its CDN.
bool Fetch(const std::wstring &url, std::string *body, HANDLE file) {
    URL_COMPONENTS parts = {sizeof parts};
    wchar_t host[256] = L"", path[2048] = L"";
    parts.lpszHostName = host;
    parts.dwHostNameLength = 256;
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = 2048;
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts)) return false;
    std::wstring agent = L"Araso-Windows";
    HINTERNET session = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        session = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                              WINHTTP_NO_PROXY_BYPASS, 0);
    }
    if (!session) return false;
    WinHttpSetTimeouts(session, 10000, 10000, 15000, 60000);
    bool ok = false;
    HINTERNET connection = WinHttpConnect(session, host, parts.nPort, 0);
    if (connection) {
        DWORD flags = parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
        HINTERNET request = WinHttpOpenRequest(connection, L"GET", path, nullptr, WINHTTP_NO_REFERER,
                                               WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
        if (request) {
            const wchar_t *headers = L"Accept: application/vnd.github+json\r\n";
            if (WinHttpSendRequest(request, headers, static_cast<DWORD>(-1L), WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
                WinHttpReceiveResponse(request, nullptr)) {
                DWORD status = 0, size = sizeof status;
                WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                    &status, &size, WINHTTP_NO_HEADER_INDEX);
                if (status == 200) {
                    ok = true;
                    std::vector<char> buffer(64 * 1024);
                    while (true) {
                        DWORD read = 0;
                        if (!WinHttpReadData(request, buffer.data(), static_cast<DWORD>(buffer.size()), &read)) { ok = false; break; }
                        if (!read) break;
                        if (body) body->append(buffer.data(), read);
                        if (file != INVALID_HANDLE_VALUE) {
                            DWORD written = 0;
                            if (!WriteFile(file, buffer.data(), read, &written, nullptr) || written != read) { ok = false; break; }
                        }
                    }
                }
            }
            WinHttpCloseHandle(request);
        }
        WinHttpCloseHandle(connection);
    }
    WinHttpCloseHandle(session);
    return ok;
}

}  // namespace

bool Get(const std::wstring &url, std::string &body) {
    body.clear();
    // A local file stands in for GitHub when trying an update before it's published (the
    // ARASO_UPDATE_FEED environment variable, as the Mac app's updateFeed default).
    if (url.rfind(L"file:///", 0) == 0) {
        std::wstring path = url.substr(8);
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;
        char buffer[4096];
        DWORD read = 0;
        while (ReadFile(file, buffer, sizeof buffer, &read, nullptr) && read) body.append(buffer, read);
        CloseHandle(file);
        return true;
    }
    return Fetch(url, &body, INVALID_HANDLE_VALUE);
}

bool Download(const std::wstring &url, const std::wstring &path) {
    if (url.rfind(L"file:///", 0) == 0) return CopyFileW(url.substr(8).c_str(), path.c_str(), FALSE) != 0;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    bool ok = Fetch(url, nullptr, file);
    CloseHandle(file);
    if (!ok) DeleteFileW(path.c_str());
    return ok;
}

std::wstring Publisher() {
#ifdef ARASO_PUBLISHER
    return ARASO_PUBLISHER;
#else
    return L"";
#endif
}

bool IsSigned(const std::wstring &path, const std::wstring &publisher) {
    if (publisher.empty()) return false;
    WINTRUST_FILE_INFO fileInfo = {sizeof fileInfo};
    fileInfo.pcwszFilePath = path.c_str();
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    WINTRUST_DATA data = {sizeof data};
    data.dwUIChoice = WTD_UI_NONE;
    data.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
    data.dwUnionChoice = WTD_CHOICE_FILE;
    data.pFile = &fileInfo;
    data.dwStateAction = WTD_STATEACTION_VERIFY;
    LONG trust = WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &data);
    bool ok = false;
    if (trust == ERROR_SUCCESS) {
        CRYPT_PROVIDER_DATA *provider = WTHelperProvDataFromStateData(data.hWVTStateData);
        CRYPT_PROVIDER_SGNR *signer = provider ? WTHelperGetProvSignerFromChain(provider, 0, FALSE, 0) : nullptr;
        CRYPT_PROVIDER_CERT *certificate = signer ? WTHelperGetProvCertFromChain(signer, 0) : nullptr;
        if (certificate && certificate->pCert) {
            wchar_t name[512] = L"";
            CertGetNameStringW(certificate->pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, name, 512);
            ok = publisher == name;
        }
    }
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &data);
    return ok;
}

}  // namespace updater

}  // namespace araso
