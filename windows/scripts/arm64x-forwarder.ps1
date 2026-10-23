# Builds arm64\ArasoTip.dll for ARM64 Windows: an ARM64X "pure forwarder" with no code of its own,
# whose exports go to ArasoTipArm64.dll in an ARM64 app and to ArasoTipX64.dll in an x64 app under
# emulation. Both kinds of app read the one registration (the registry isn't split between them),
# so the text service's path has to load in both. Needs the MSVC ARM64 tools in the environment
# (CI: ilammy/msvc-dev-cmd with arch amd64_arm64).
#   pwsh windows/scripts/arm64x-forwarder.ps1 <out folder>
param([string]$Out)
$ErrorActionPreference = "Stop"
$work = Join-Path ([IO.Path]::GetTempPath()) "araso-arm64x"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Content "$work\empty.cpp" ""
$exports = "DllGetClassObject", "DllCanUnloadNow", "DllRegisterServer", "DllUnregisterServer"
function Def([string]$target) {
    "EXPORTS`r`n" + (($exports | ForEach-Object { "    $_=$target.$_" }) -join "`r`n")
}
Set-Content "$work\arm64.def" (Def "ArasoTipArm64")
Set-Content "$work\x64.def" (Def "ArasoTipX64")
Push-Location $work
try {
    cl /nologo /c /Zl /Foempty_arm64.obj empty.cpp
    if ($LASTEXITCODE) { throw "cl (ARM64) failed" }
    cl /nologo /c /Zl /arm64EC /Foempty_x64.obj empty.cpp
    if ($LASTEXITCODE) { throw "cl (ARM64EC) failed" }
    link /nologo /dll /noentry /machine:arm64x /defArm64Native:arm64.def /def:x64.def empty_arm64.obj empty_x64.obj /out:ArasoTip.dll
    if ($LASTEXITCODE) { throw "link (ARM64X) failed" }
}
finally { Pop-Location }
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item "$work\ArasoTip.dll" (Join-Path $Out "ArasoTipForwarder.dll")
Write-Host "ARM64X forwarder: $(Join-Path $Out 'ArasoTipForwarder.dll')"
