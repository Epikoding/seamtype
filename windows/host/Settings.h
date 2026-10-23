// `ArasoHost.exe --settings <tab>`: the settings window (SettingsWindow.swift on macOS), its own
// process. It reads and writes the same JSON files through the bridge, and tells the host when
// they changed.
#pragma once

#include <string>

namespace araso {

int RunSettings(const std::string &tab);

}  // namespace araso
