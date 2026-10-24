# The Windows input method's C++: the text service (ArasoTip.dll, built for x64, x86 and ARM64,
# since every app loads it) and the host (ArasoHost.exe, x64 and ARM64, which loads the Swift
# ArasoBridge.dll at run time). See docs/windows-port.md.
#   cmake -S windows -B build/windows -A x64 -DARASO_VERSION=0.2.4
#   cmake --build build/windows --config Release
cmake_minimum_required(VERSION 3.20)
project(Araso LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
option(ARASO_HOST "Build ArasoHost.exe too (not for x86)" ON)
set(ARASO_VERSION "0.0.0" CACHE STRING "Version written into the binaries")
set(ARASO_PUBLISHER "" CACHE STRING "The signing certificate's subject name, which the updater requires of an installer")

string(REPLACE "." "," ARASO_VERSION_COMMAS "${ARASO_VERSION},0")
add_compile_definitions(UNICODE _UNICODE)
if(MSVC)
  add_compile_options(/W4 /wd4100 /utf-8 /EHsc /permissive-)
endif()
configure_file(version.h.in "${CMAKE_CURRENT_BINARY_DIR}/araso_version.h" @ONLY)
include_directories("${CMAKE_CURRENT_BINARY_DIR}")

set(COMMON common/Common.cpp common/Json.cpp)

file(GLOB TIP_SOURCES tip/*.cpp)
add_library(ArasoTip SHARED ${TIP_SOURCES} ${COMMON} tip/ArasoTip.rc tip/ArasoTip.def)
target_link_libraries(ArasoTip PRIVATE ole32 oleaut32 uuid user32 advapi32)

if(ARASO_HOST AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/host/Main.cpp")
  file(GLOB HOST_SOURCES host/*.cpp)
  add_executable(ArasoHost WIN32 ${HOST_SOURCES} ${COMMON} host/ArasoHost.rc)
  if(ARASO_PUBLISHER)
    target_compile_definitions(ArasoHost PRIVATE ARASO_PUBLISHER=L"${ARASO_PUBLISHER}")
  endif()
  target_link_libraries(ArasoHost PRIVATE ole32 oleaut32 uuid user32 gdi32 d2d1 dwrite advapi32 shell32 comctl32
                        winhttp wintrust crypt32 dwmapi uxtheme shlwapi version imm32 shcore)
  if(MSVC)
    # The manifest is ArasoHost.rc's (PerMonitorV2, common controls 6), not the linker's own.
    target_link_options(ArasoHost PRIVATE /ENTRY:wWinMainCRTStartup /MANIFEST:NO)
  endif()
endif()
