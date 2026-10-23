#!/bin/sh
# Compiles the Windows C++ (the text service and the host) with zig's mingw-w64 toolchain, on macOS
# or Linux, to catch errors before the Windows CI builds it with MSVC. Links the text service DLL
# and the host exe (the host loads ArasoBridge.dll at run time, so it needs no Swift to link).
#   windows/scripts/check-cross.sh [x86_64|x86|aarch64]
set -eu
cd "$(dirname "$0")/.."
arch="${1:-x86_64}"
target="$arch-windows-gnu"
out="../build/windows-cross/$arch"
mkdir -p "$out"
flags="-std=c++17 -O1 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wno-cast-function-type -DUNICODE -D_UNICODE"
version="${ARASO_VERSION:-0.0.0}"
commas="$(echo "$version" | tr '.' ',' ),0"
rcflags="-DARASO_VERSION_COMMAS=$commas -DARASO_VERSION_STRING=\\\"$version\\\""

echo "text service ($target)"
zig rc /:target "$arch" /i tip $(echo "/dARASO_VERSION_COMMAS=$commas") "/dARASO_VERSION_STRING=\"$version\"" /fo "$out/ArasoTip.res" -- tip/ArasoTip.rc
zig c++ -target "$target" $flags -shared -o "$out/ArasoTip.dll" \
    tip/*.cpp common/Common.cpp common/Json.cpp "$out/ArasoTip.res" tip/ArasoTip.def \
    -lole32 -loleaut32 -luuid -luser32 -ladvapi32 -static-libgcc -static-libstdc++

if [ ! -f host/Main.cpp ]; then echo "ok: $out (no host yet)"; exit 0; fi
echo "host ($target)"
zig rc /:target "$arch" /i host $(echo "/dARASO_VERSION_COMMAS=$commas") "/dARASO_VERSION_STRING=\"$version\"" /fo "$out/ArasoHost.res" -- host/ArasoHost.rc
zig c++ -target "$target" $flags -mwindows -municode -o "$out/ArasoHost.exe" \
    host/*.cpp common/Common.cpp common/Json.cpp "$out/ArasoHost.res" \
    -lole32 -loleaut32 -luuid -luser32 -lgdi32 -lgdiplus -ladvapi32 -lshell32 -lcomctl32 -lwinhttp -lwintrust \
    -lcrypt32 -ldwmapi -luxtheme -lshlwapi -lversion -limm32 -static-libgcc -static-libstdc++
echo "ok: $out"
