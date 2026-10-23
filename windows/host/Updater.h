// Updates, as on macOS (Updater.swift): GitHub's latest release is asked for its version (nothing
// else is sent) once a day and from About; Install downloads Araso-Setup.exe, requires its
// Authenticode signature to be valid and from Araso's publisher, then runs it.
#pragma once

#include "../common/Common.h"

#include <string>

namespace araso {

namespace updater {

constexpr const wchar_t *kLatest = L"https://api.github.com/repos/nyttastudio/araso/releases/latest";

/// GET over HTTPS; false on any failure or a status other than 200.
bool Get(const std::wstring &url, std::string &body);
/// Downloads to `path`.
bool Download(const std::wstring &url, const std::wstring &path);
/// Whether `path` carries a valid Authenticode signature whose signer is `publisher` (the
/// subject's common name). An empty publisher (an unsigned build) accepts nothing.
bool IsSigned(const std::wstring &path, const std::wstring &publisher);
/// The publisher releases are signed by, set at build time (ARASO_PUBLISHER); empty when unsigned.
std::wstring Publisher();

}  // namespace updater

}  // namespace araso
