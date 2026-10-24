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
sed -e "s/@ARASO_VERSION@/$version/" -e "s/@ARASO_VERSION_COMMAS@/$commas/" version.h.in > "$out/araso_version.h"
flags="$flags -I$out"

echo "text service ($target)"
zig rc /:target "$arch" /i tip /i "$out" /fo "$out/ArasoTip.res" -- tip/ArasoTip.rc
zig c++ -target "$target" $flags -shared -o "$out/ArasoTip.dll" \
    tip/*.cpp common/Common.cpp common/Json.cpp "$out/ArasoTip.res" tip/ArasoTip.def \
    -lole32 -loleaut32 -luuid -luser32 -ladvapi32

if [ ! -f host/Main.cpp ]; then echo "ok: $out (no host yet)"; exit 0; fi
echo "host ($target)"
zig rc /:target "$arch" /i host /i "$out" /fo "$out/ArasoHost.res" -- host/ArasoHost.rc
zig c++ -target "$target" $flags -municode -Wl,--subsystem,windows -o "$out/ArasoHost.exe" \
    host/*.cpp common/Common.cpp common/Json.cpp "$out/ArasoHost.res" \
    -lole32 -loleaut32 -luuid -luser32 -lgdi32 -ld2d1 -ldwrite -ladvapi32 -lshell32 -lcomctl32 -lwinhttp -lwintrust \
    -lcrypt32 -ldwmapi -luxtheme -lshlwapi -lversion -limm32 -lshcore
echo "ok: $out"
