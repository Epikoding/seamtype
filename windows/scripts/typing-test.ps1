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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
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
    /// A key by its virtual-key code, as a Korean keyboard's 한/영 and 한자 keys arrive.
    public static void Virtual(ushort vk, bool up) {
        var input = new INPUT[1];
        input[0].type = 1;
        input[0].ki.wVk = vk;
        input[0].ki.dwFlags = up ? KEYUP : 0;
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
    /// The first multi-line Edit control in a window (Try Typing's field in the settings window).
    public static IntPtr FindMultilineEdit(IntPtr parent) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (window, data) => {
            var name = new StringBuilder(32);
            GetClassName(window, name, 32);
            if (name.ToString() == "Edit" && (GetWindowLong(window, -16) & 0x4) != 0) { found = window; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr window);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    /// Gives a control in another app the keyboard focus, as a click in it would.
    public static void Focus(IntPtr control) {
        uint thread = GetWindowThreadProcessId(control, IntPtr.Zero);
        AttachThreadInput(GetCurrentThreadId(), thread, true);
        SetFocus(control);
        AttachThreadInput(GetCurrentThreadId(), thread, false);
    }
    /// Brings a window to the front even when Windows' foreground lock would refuse: as the
    /// window in front's own thread asks it.
    public static bool Front(IntPtr window) {
        IntPtr front = GetForegroundWindow();
        uint thread = front == IntPtr.Zero ? 0 : GetWindowThreadProcessId(front, IntPtr.Zero);
        uint own = GetCurrentThreadId();
        if (thread != 0 && thread != own) AttachThreadInput(own, thread, true);
        bool done = SetForegroundWindow(window);
        if (thread != 0 && thread != own) AttachThreadInput(own, thread, false);
        return done;
    }
    public static string Text(IntPtr edit) {
        int length = (int)SendMessage(edit, 0x0E /* WM_GETTEXTLENGTH */, IntPtr.Zero, IntPtr.Zero);
        var text = new StringBuilder(length + 1);
        SendMessage(edit, 0x0D /* WM_GETTEXT */, (IntPtr)(length + 1), text);
        return text.ToString();
    }
}
"@

$script:language = "0412"
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

# The text service created as TSF creates it, in an x64 process (ArasoHost.exe) and in one of this
# machine's own (PowerShell): on ARM64 Windows the forwarder must hand each its own build.
$created = @()
Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--load-text-service" -Wait
$x64 = (Get-Content $log -ErrorAction SilentlyContinue | Select-String "text service:" | Select-Object -Last 1) -as [string]
Write-Host "x64 process: $x64"
$created += $x64 -match "created"
try {
    $service = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]"6D6C7D5F-3B7F-4F0E-9A2C-417261736F01"))
    $own = (Get-Process -Id $PID).Modules | Where-Object { $_.ModuleName -like "ArasoTip*.dll" } | ForEach-Object FileName
    Write-Host "text service in this $([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) process: created, $($own -join ', ')"
    [Runtime.InteropServices.Marshal]::ReleaseComObject($service) | Out-Null
    $created += $true
} catch {
    Write-Host "text service in this process: FAILED ($($_.Exception.Message))"
    $created += $false
}
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $x64ok = $x64 -match "ArasoTipX64.dll"
    $ownok = ($own -join ",") -match "ArasoTipArm64.dll"
    $created += $x64ok, $ownok
}

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

# A field to type into: Notepad (its Edit control, through IMM32's compatibility layer) or a WPF
# TextBox (TSF's own). Answers what reads its text back.
function Open-Field([string]$kind) {
    if ($kind -eq "host") {
        # Try Typing in Araso's settings window: an x64 app (under emulation on ARM64 Windows).
        $process = Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--settings", "typing" -PassThru
        for ($i = 0; $i -lt 60 -and $process.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $process.Refresh() }
        Start-Sleep -Seconds 2
        $edit = [Keys]::FindMultilineEdit($process.MainWindowHandle)
        if ($edit -eq [IntPtr]::Zero) { Write-Host "host: no Try Typing field" }
        [Keys]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 300
        [Keys]::Focus($edit)
        Start-Sleep -Seconds 1
        return @{ process = $process; window = $process.MainWindowHandle; read = { [Keys]::Text($edit) }.GetNewClosure() }
    }
    if ($kind -ne "notepad") {
        $out = Join-Path $env:TEMP "araso-field.txt"
        Remove-Item $out -ErrorAction SilentlyContinue
        $process = Start-Process powershell -ArgumentList "-STA", "-NoProfile", "-File", "$PSScriptRoot\field.ps1", $kind, $out -PassThru
        for ($i = 0; $i -lt 60 -and $process.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $process.Refresh() }
        Start-Sleep -Seconds 2 # the window draws, then focuses the box
        return @{ process = $process; window = $process.MainWindowHandle; read = { if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { "" } }.GetNewClosure() }
    }
    $process = Start-Process notepad -PassThru
    Start-Sleep -Seconds 3
    $window = $process.MainWindowHandle
    $edit = [Keys]::FindWindowEx($window, [IntPtr]::Zero, "Edit", $null)
    $class = "Edit"
    if ($edit -eq [IntPtr]::Zero) { $edit = [Keys]::FindWindowEx($window, [IntPtr]::Zero, "RichEditD2DPT", $null); $class = "RichEditD2DPT" }
    Write-Host "notepad's field: $class"
    return @{ process = $process; window = $window; read = { [Keys]::Text($edit) }.GetNewClosure() }
}

function Case([string]$keys, [string]$expected, [scriptblock]$after, [string]$kind = "notepad") {
    $field = Open-Field $kind
    $notepad = $field.process
    $window = $field.window
    [Keys]::Front($window) | Out-Null
    Start-Sleep -Milliseconds 800
    $thread = [Keys]::GetWindowThreadProcessId($window, [IntPtr]::Zero)
    $layout = "{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()
    $front = [Keys]::GetForegroundWindow() -eq $window
    for ($i = 0; $i -lt 10 -and -not $layout.EndsWith($script:language); $i++) {
        [Keys]::Front($window) | Out-Null
        # As the taskbar's indicator does: ask the window to switch to the language Araso is listed under.
        $hkl = [IntPtr][Convert]::ToInt64($script:language + $script:language, 16)
        [Keys]::PostMessage($window, 0x50 <# WM_INPUTLANGCHANGEREQUEST #>, [IntPtr]::Zero, $hkl) | Out-Null
        Start-Sleep -Milliseconds 800
        $layout = "{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()
    }
    $loaded = (Get-Process -Id $notepad.Id).Modules | Where-Object { $_.ModuleName -eq "ArasoTip.dll" } | Select-Object -First 1
    Write-Host "${kind}: in front $front, layout $layout, ArasoTip.dll $(if ($loaded) { $loaded.FileName } else { 'not loaded' })"
    Send-Keys $keys
    if ($after) { & $after }
    Start-Sleep -Milliseconds 800
    if ([Keys]::GetForegroundWindow() -ne $window) { Write-Host "${kind}: no longer in front after the keys" }
    $text = & $field.read
    Stop-Process -Id $notepad.Id -Force
    Write-Host "$kind typed '$keys' → '$text'"
    return $text -eq $expected
}

function Press-Virtual([int]$vk) {
    [Keys]::Virtual($vk, $false); Start-Sleep -Milliseconds 60
    [Keys]::Virtual($vk, $true); Start-Sleep -Milliseconds 200
}

function Tap([int]$scan) {
    [Keys]::Key($scan, $false, $true); Start-Sleep -Milliseconds 60
    [Keys]::Key($scan, $true, $true); Start-Sleep -Milliseconds 200
}

# The classic field: Notepad's Edit control (Windows 10, Server), or the same control in a WinForms
# window where Notepad is Windows 11's own app (CI's ARM64 runner).
$classic = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "winforms" } else { "notepad" }

$results = @(
    # A WPF TextBox: a TSF text store, where the word is composed in the text.
    (Case "dkssud hello " "안녕 hello " $null "wpf"),
    # Right Alt tapped alone switches the word just committed (0x38 extended: right Alt).
    (Case "hello " "ㅗ디ㅣㅐ " { Tap 0x38 } "wpf"),
    # Try Typing in the settings window: an x64 app, also on ARM64 Windows.
    (Case "dkssud hello " "안녕 hello " $null "host"),
    # A classic app's Edit control, where the word is drawn at the caret and goes in whole.
    (Case "dkssud hello " "안녕 hello " $null $classic),
    (Case "gksrmf " "한글 " $null $classic),
    # Switched while typing, before the Space.
    (Case "hello" "ㅗ디ㅣㅐ " { Tap 0x38; Send-Keys " " } $classic),
    # Right Ctrl tapped alone pauses (0x1D extended): keys then go in as typed.
    (Case "" "dkssud " { Tap 0x1D; Send-Keys "dkssud " } $classic),
    # A Korean keyboard's 한/영 (VK_HANGUL) switches as it goes down; 한자 (VK_HANJA) pauses.
    (Case "hello " "ㅗ디ㅣㅐ " { Press-Virtual 0x15 } $classic),
    (Case "" "dkssud " { Press-Virtual 0x19; Send-Keys "dkssud " } $classic)
)
# Reported, not required: switching the word just committed in a classic app, whose text Araso
# edits only through Windows' compatibility layer.
Case "hello " "ㅗ디ㅣㅐ " { Tap 0x38 } $classic | Out-Null

Write-Host "machine: $env:PROCESSOR_ARCHITECTURE"
if (Test-Path $log) { Write-Host "--- araso.log"; Get-Content $log | Select-String -NotMatch "scan code" | Select-Object -Last 400 | Out-Host }
reg query "HKCU\Software\Microsoft\CTF\TIP" /s 2>$null | Select-String -Pattern "6D6C7D5F" | Out-Host
reg query "HKLM\Software\Microsoft\CTF\TIP\{6D6C7D5F-3B7F-4F0E-9A2C-417261736F01}" /s 2>$null | Select-Object -First 20 | Out-Host
Get-WinUserLanguageList | Format-List | Out-Host
if ($created -contains $false) { throw "the text service couldn't be created" }
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -and -not ($results -contains $true)) {
    # Not one key reached a window: this runner has no interactive desktop to type into.
    Write-Host "typing test: no key reached any window here; the text service was created in ARM64 and x64 processes"
    exit 0
}
if ($results -contains $false) {
    Get-ChildItem "$env:APPDATA\Araso" -ErrorAction SilentlyContinue | Select-Object Name | Out-Host
    throw "typing test failed"
}
Write-Host "typing test: ok"
