# Starts ArasoHost.exe --server from a staged folder and types through its pipe as the text service
# does: attach, the keys of "dkssud" with a snapshot of the field, then blur. The field must end up
# "안녕", composed while typed and put in by blur. The CI's check that the host serves, not only builds.
#   pwsh windows/scripts/pipe-test.ps1 build/stage
param([string]$Stage = "build/stage")
$ErrorActionPreference = "Stop"

$server = Start-Process -FilePath (Join-Path $Stage "ArasoHost.exe") -ArgumentList "--server" -PassThru
try {
    $name = "Araso.$((Get-Process -Id $PID).SessionId).$env:USERNAME"
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $name, [System.IO.Pipes.PipeDirection]::InOut)
    # The host warms its models up before it serves.
    $pipe.Connect(60000)
    $pipe.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message

    function Send([hashtable]$request) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 8 -Compress))
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
        $buffer = New-Object byte[] 65536
        $answer = New-Object System.IO.MemoryStream
        do {
            $read = $pipe.Read($buffer, 0, $buffer.Length)
            $answer.Write($buffer, 0, $read)
        } while (-not $pipe.IsMessageComplete)
        return [Text.Encoding]::UTF8.GetString($answer.ToArray()) | ConvertFrom-Json
    }

    # The field, as the text service sees it, and its edits made as TextService::ApplyOps does.
    $script:text = ""
    $script:marked = $null
    $script:caret = 0
    function Context {
        $context = @{ selection = @($script:caret, 0); text = $script:text; start = 0 }
        if ($script:marked) { $context.marked = $script:marked }
        return $context
    }
    function Apply($ops) {
        foreach ($op in $ops) {
            if ($op.replace) { $at = $op.replace[0]; $length = $op.replace[1] }
            elseif ($script:marked) { $at = $script:marked[0]; $length = $script:marked[1] }
            else { $at = $script:caret; $length = 0 }
            $script:text = $script:text.Substring(0, $at) + $op.text + $script:text.Substring($at + $length)
            $script:marked = if ($op.kind -eq "mark" -and $op.text.Length -gt 0) { @($at, $op.text.Length) } else { $null }
            $script:caret = $at + $op.text.Length
        }
    }

    $attached = Send @{ op = "attach"; app = "notepad.exe"; window = 0; pid = $PID }
    $client = $attached.reply.client
    if (-not $client) { throw "no client id: $($attached | ConvertTo-Json -Depth 8)" }
    Send @{ op = "focus"; client = $client; app = "notepad.exe" } | Out-Null

    $scans = @{ d = 0x20; k = 0x25; s = 0x1F; u = 0x16 }
    foreach ($ch in "dkssud".ToCharArray()) {
        $key = @{ vk = [int][char]::ToUpper($ch); scan = $scans["$ch"]; extended = $false; shift = $false; ctrl = $false;
                  alt = $false; win = $false; capsLock = $false }
        $answer = Send @{ op = "key"; client = $client; key = $key; context = (Context) }
        if (-not $answer.reply.handled) { throw "key $ch wasn't taken: $($answer | ConvertTo-Json -Depth 8)" }
        Apply $answer.reply.ops
    }
    if ($script:text -ne "안녕" -or -not $script:marked) { throw "typing gave '$script:text' (marked: $script:marked)" }
    $answer = Send @{ op = "blur"; client = $client; context = (Context) }
    Apply $answer.reply.ops
    if ($script:text -ne "안녕" -or $script:marked) { throw "blur left '$script:text' (marked: $script:marked)" }
    $model = Send @{ op = "settings" }
    Write-Host "pipe test: the settings model says version '$($model.settings.version)'"
    $menu = Send @{ op = "menu"; client = $client }
    if (-not ($menu.reply.menu | Where-Object { $_.id -eq "settings" })) { throw "no menu" }
    Send @{ op = "detach"; client = $client } | Out-Null
    $pipe.Dispose()
    Write-Host "pipe test: ok ($script:text)"
}
finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}
