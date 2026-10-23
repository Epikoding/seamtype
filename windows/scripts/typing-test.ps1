# Real typing through the installed input method (scripts/typing-test on macOS): installs
# Araso-Setup.exe silently, makes Araso the input method for new windows, opens Notepad, sends key
# events (scan codes, as a keyboard does) and reads Notepad's text back.
#   pwsh windows/scripts/typing-test.ps1 build/Araso-Setup.exe
# Takes over the keyboard and the focus: run it on a machine nobody is using (the CI's).
param([string]$Installer = "build/Araso-Setup.exe")
$ErrorActionPreference = "Stop"
# The text service and the host log here too (machine-wide, so Notepad and the host both see it).
$log = Join-Path $env:TEMP "araso.log"
[Environment]::SetEnvironmentVariable("ARASO_LOG", $log, "Machine")
[Environment]::SetEnvironmentVariable("ARASO_LOG", $log, "User")
$env:ARASO_LOG = $log

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Keys {
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll")] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr w, StringBuilder l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool InstallLayoutOrTip(string profile, uint flags);
    [DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool SetDefaultLayoutOrTip(string profile, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    const uint SCANCODE = 0x8, KEYUP = 0x2, EXTENDED = 0x1;
    public static void Key(ushort scan, bool up, bool extended) {
        var input = new INPUT[1];
        input[0].type = 1;
        input[0].ki.wScan = scan;
        input[0].ki.dwFlags = SCANCODE | (up ? KEYUP : 0) | (extended ? EXTENDED : 0);
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }
    public static string Text(IntPtr edit) {
        int length = (int)SendMessage(edit, 0x0E /* WM_GETTEXTLENGTH */, IntPtr.Zero, IntPtr.Zero);
        var text = new StringBuilder(length + 1);
        SendMessage(edit, 0x0D /* WM_GETTEXT */, (IntPtr)(length + 1), text);
        return text.ToString();
    }
}
"@

$tip = "0412:{6D6C7D5F-3B7F-4F0E-9A2C-417261736F01}{6D6C7D5F-3B7F-4F0E-9A2C-417261736F02}"
# Only the installer is waited for: -Wait would also wait for the host it starts, which stays.
# (Not $installer: PowerShell's names ignore case, and the [string] parameter would take the process.)
$setup = Start-Process -FilePath $Installer -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -PassThru
$setup.WaitForExit()
if ($setup.ExitCode -ne 0) { throw "install failed ($($setup.ExitCode))" }
Write-Host "installed"
$folder = "$env:ProgramFiles\Araso"
if (-not (Test-Path "$folder\ArasoTip.dll")) { throw "not installed in $folder" }
[Keys]::InstallLayoutOrTip($tip, 0) | Out-Null
if (-not [Keys]::SetDefaultLayoutOrTip($tip, 0)) { Write-Host "SetDefaultLayoutOrTip failed" }
# A new window starts in the default input method only when it overrides the language list's first.
Set-WinDefaultInputMethodOverride -InputTip $tip
# A host started by the installer doesn't have ARASO_LOG: start it afresh.
Get-Process ArasoHost -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--server"
Start-Sleep -Seconds 8   # the host warms its models up

# Letters' scan codes on a US keyboard.
$scans = @{}
$rows = @(@("qwertyuiop", 0x10), @("asdfghjkl", 0x1E), @("zxcvbnm", 0x2C))
foreach ($row in $rows) { for ($i = 0; $i -lt $row[0].Length; $i++) { $scans[[string]$row[0][$i]] = $row[1] + $i } }
$scans[" "] = 0x39

function Send-Keys([string]$keys) {
    foreach ($ch in $keys.ToCharArray()) {
        $scan = $scans[[string]$ch]
        [Keys]::Key($scan, $false, $false); Start-Sleep -Milliseconds 40
        [Keys]::Key($scan, $true, $false); Start-Sleep -Milliseconds 40
    }
}

function Case([string]$keys, [string]$expected, [scriptblock]$after) {
    $notepad = Start-Process notepad -PassThru
    Start-Sleep -Seconds 3
    $window = $notepad.MainWindowHandle
    [Keys]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Milliseconds 500
    $edit = [Keys]::FindWindowEx($window, [IntPtr]::Zero, "Edit", $null)
    if ($edit -eq [IntPtr]::Zero) { $edit = [Keys]::FindWindowEx($window, [IntPtr]::Zero, "RichEditD2DPT", $null) }
    $thread = [Keys]::GetWindowThreadProcessId($window, [IntPtr]::Zero)
    $layout = "{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()
    if (-not $layout.EndsWith("0412")) {
        # As the taskbar's indicator does: ask the window to switch to Korean, whose input method is Araso.
        [Keys]::PostMessage($window, 0x50 <# WM_INPUTLANGCHANGEREQUEST #>, [IntPtr]::Zero, [IntPtr]0x04120412) | Out-Null
        Start-Sleep -Milliseconds 800
        $layout = "{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()
    }
    $loaded = (Get-Process -Id $notepad.Id).Modules | Where-Object { $_.ModuleName -eq "ArasoTip.dll" }
    Write-Host "notepad: layout $layout, ArasoTip.dll $(if ($loaded) { 'loaded' } else { 'not loaded' })"
    Send-Keys $keys
    if ($after) { & $after }
    Start-Sleep -Milliseconds 800
    $text = [Keys]::Text($edit)
    Stop-Process -Id $notepad.Id -Force
    Write-Host "typed '$keys' → '$text'"
    return $text -eq $expected
}

function Tap([int]$scan) {
    [Keys]::Key($scan, $false, $true); Start-Sleep -Milliseconds 60
    [Keys]::Key($scan, $true, $true); Start-Sleep -Milliseconds 200
}

$results = @(
    (Case "dkssud hello " "안녕 hello " $null),
    (Case "gksrmf " "한글 " $null),
    # Right Alt tapped alone switches the word just committed (0x38 extended: right Alt).
    (Case "hello " "ㅗ디ㅣㅐ " { Tap 0x38 }),
    # Right Ctrl tapped alone pauses (0x1D extended): keys then go in as typed.
    (Case "" "dkssud " { Tap 0x1D; Send-Keys "dkssud " })
)
if (Test-Path $log) { Write-Host "--- araso.log"; Get-Content $log | Select-Object -Last 60 | Out-Host }
reg query "HKCU\Software\Microsoft\CTF\TIP" /s 2>$null | Select-String -Pattern "6D6C7D5F" | Out-Host
reg query "HKLM\Software\Microsoft\CTF\TIP\{6D6C7D5F-3B7F-4F0E-9A2C-417261736F01}" /s 2>$null | Select-Object -First 20 | Out-Host
Get-WinUserLanguageList | Format-List | Out-Host
if ($results -contains $false) {
    Get-ChildItem "$env:APPDATA\Araso" -ErrorAction SilentlyContinue | Select-Object Name | Out-Host
    throw "typing test failed"
}
Write-Host "typing test: ok"
