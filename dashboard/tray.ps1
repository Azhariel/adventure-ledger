<#
Adventure Ledger tray icon: runs and watches the live server (server.py) and the AH fetcher (fetcher.py).

    tray.bat                 (wowstats live starts it this way: hidden, no console)
    tray.ps1 -Stop           ask a running tray, the server and the fetcher to stop (wowstats stop)
    tray.ps1 -NoGui          dot-source it to get the functions without the icon (tests)

Green: server and fetcher running, last fetch under 1.5 x ah_every old. Amber: one stopped, fetch failed or overdue.
Grey: both stopped. A fetcher without bnet_id in ledger.cfg is "not set up", which never makes the icon amber.
Messages go to tray.log in the data folder. Windows PowerShell 5.1, nothing to install.
#>
param(
    [int]$Port = 8737,
    [switch]$NoOpen,   # don't open the page (tests)
    [switch]$Stop,
    [switch]$NoGui
)

$Dash = $PSScriptRoot
$Root = Split-Path $Dash -Parent
$MutexName = 'Global\AdventureLedgerTray'
$LogMax = 1000000
$Dot = [char]0x00B7

function Read-LedgerConfig([string]$Path) {
    # same rules as server.read_config: key = value lines, # comments, empty values ignored
    $cfg = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.IndexOf('=') -lt 0) { continue }
        $i = $line.IndexOf('=')
        $v = $line.Substring($i + 1).Trim()
        if ($v) { $cfg[$line.Substring(0, $i).Trim()] = $v }
    }
    return $cfg
}

function Get-DataDir($Cfg) {
    # same rule as server.DATA: LEDGER_DATA, then data = in ledger.cfg, then <repo>\data
    $d = $env:LEDGER_DATA
    if (-not $d) { $d = $Cfg['data'] }
    if (-not $d) { $d = Join-Path $Root 'data' }
    return [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $d))
}

function Write-TrayLog([string]$Path, [string]$Message, [string]$Level = 'INFO') {
    $line = '{0} {1} tray: {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message, [Environment]::NewLine
    try {
        # rotate like ledgerlog's RotatingFileHandler: tray.log -> .1 -> .2 -> .3, oldest dropped
        if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length + $line.Length -gt $LogMax)) {
            for ($n = 3; $n -ge 1; $n--) {
                $src = if ($n -eq 1) { $Path } else { "$Path.$($n - 1)" }
                if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination "$Path.$n" -Force }
            }
        }
        [IO.File]::AppendAllText($Path, $line, (New-Object Text.UTF8Encoding $false))
    } catch { }   # a log we can't write must not take the tray down
}

function Format-Clock($Epoch) {
    if ($null -eq $Epoch) { return $null }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$Epoch).LocalDateTime.ToString('HH:mm')
}

function Get-TrayState {
    # Pure: colour and tooltip from what the tick saw. $Status is fetcher_status.json (or $null).
    param([bool]$ServerUp, [bool]$ServerProcAlive, [bool]$FetcherUp, [bool]$NotSetUp, $Status,
          [int]$EveryMin = 60, [double]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    if ($ServerUp) { $live = 'Live: on' }
    elseif ($ServerProcAlive) { $live = 'Live: not answering' }
    else { $live = 'Live: stopped' }

    $err = $null; $lastOk = $null; $next = $null
    if ($Status) { $err = $Status.error; $lastOk = $Status.last_ok; $next = $Status.next }
    $ahBad = $true
    if ($NotSetUp) { $ah = 'AH: not set up'; $ahBad = $false }
    elseif (-not $FetcherUp) { $ah = 'AH: stopped' }
    elseif ($err) { $ah = "AH: fetch failed: $err" }
    elseif ($null -eq $lastOk) { $ah = 'AH: no fetch yet' }
    elseif ($Now - $lastOk -ge 1.5 * $EveryMin * 60) { $ah = "AH: overdue, last fetch $(Format-Clock $lastOk)" }
    else {
        $ah = "AH: last fetch $(Format-Clock $lastOk)"
        if ($null -ne $next) { $ah += ", next $(Format-Clock $next)" }
        $ahBad = $false
    }

    if ($NotSetUp) { $colour = if ($ServerUp) { 'green' } else { 'grey' } }
    elseif (-not $ServerUp -and -not $FetcherUp) { $colour = 'grey' }
    elseif (-not $ServerUp -or $ahBad) { $colour = 'amber' }
    else { $colour = 'green' }

    $tip = "$live $Dot $ah"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }   # NotifyIcon.Text takes 63 characters at most
    return [pscustomobject]@{ Colour = $colour; Tip = $tip }
}

function Test-NotSetUp($Cfg, $Status, [bool]$FetcherUp) {
    # no bnet_id, or the fetcher said so (bnet_secret missing) and isn't running with a newer config
    if (-not $Cfg['bnet_id']) { return $true }
    return ($Status -and $Status.error -eq 'not set up' -and -not $FetcherUp)
}

function Read-FetcherStatus([string]$Path) {
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Test-LockHeld([string]$Path) {
    # fetcher.py holds byte 0 of fetcher.lock while it runs (msvcrt.locking)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'ReadWrite') } catch { return $false }
    try { $fs.Lock(0, 1); $fs.Unlock(0, 1); return $false } catch { return $true } finally { $fs.Close() }
}

function Test-ServerUp([int]$P) {
    try {
        $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$P/status")
        $req.Timeout = 2000; $req.ReadWriteTimeout = 2000; $req.Proxy = $null
        $resp = $req.GetResponse()
        $ok = [int]$resp.StatusCode -eq 200
        $resp.Close()
        return $ok
    } catch { return $false }
}

function Send-ServerStop([int]$P) {
    try {
        $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$P/stop")
        $req.Method = 'POST'; $req.Headers.Add('X-Ledger', 'stop'); $req.ContentLength = 0
        $req.Timeout = 3000; $req.Proxy = $null
        $req.GetResponse().Close()
        return $true
    } catch { return $false }
}

function Get-StartupLinkPath {
    return Join-Path ([Environment]::GetFolderPath('Startup')) 'Adventure Ledger.lnk'
}

function New-StartupLink([string]$LinkPath = (Get-StartupLinkPath)) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($LinkPath)
    $lnk.TargetPath = Join-Path $Dash 'tray.bat'
    $lnk.WorkingDirectory = $Dash
    $lnk.WindowStyle = 7   # minimised: tray.bat's console only flashes
    $lnk.Description = 'Adventure Ledger tray: live server and AH fetcher'
    $lnk.Save()
}

function Remove-StartupLink([string]$LinkPath = (Get-StartupLinkPath)) {
    if (Test-Path -LiteralPath $LinkPath) { Remove-Item -LiteralPath $LinkPath -Force }
}

if ($NoGui) { return }

$Cfg = Read-LedgerConfig (Join-Path $Root 'ledger.cfg')
$Data = Get-DataDir $Cfg
New-Item -ItemType Directory -Force -Path $Data | Out-Null
$LogPath = Join-Path $Data 'tray.log'
$StatusPath = Join-Path $Data 'fetcher_status.json'
$LockPath = Join-Path $Data 'fetcher.lock'
function Log([string]$Message, [string]$Level = 'INFO') { Write-TrayLog $LogPath $Message $Level }

if ($Stop) {
    # wowstats stop: the tray (if any) stops its children and quits; also stop anything it didn't start
    $tray = $null
    $trayRunning = [Threading.Mutex]::TryOpenExisting($MutexName, [ref]$tray)
    if ($trayRunning) { $tray.Dispose(); [IO.File]::WriteAllText((Join-Path $Data 'tray_stop'), '') }
    if (Send-ServerStop $Port) { 'Live server stopped.' } else { 'Live server was not running.' }
    if (Test-LockHeld $LockPath) {
        [IO.File]::WriteAllText((Join-Path $Data 'fetcher_stop'), '')
        'AH fetcher asked to stop (it finishes a fetch in progress first).'
    }
    if ($trayRunning) {
        $until = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $until -and [Threading.Mutex]::TryOpenExisting($MutexName, [ref]$tray)) {
            $tray.Dispose(); Start-Sleep -Milliseconds 500
        }
        if ([Threading.Mutex]::TryOpenExisting($MutexName, [ref]$tray)) { $tray.Dispose(); 'Tray is still stopping.' }
        else { 'Tray stopped.' }
    }
    exit 0
}

function Open-Dashboard {
    if (Test-ServerUp $Port) { Start-Process "http://127.0.0.1:$Port/" }
    elseif (Test-Path -LiteralPath (Join-Path $Data 'dashboard.html')) { Start-Process (Join-Path $Data 'dashboard.html') }
}

$created = $false
$Mutex = New-Object Threading.Mutex($true, $MutexName, [ref]$created)
if (-not $created) {
    # one tray per user session; a second `wowstats live` just opens the page, like serve.bat did
    Log 'already running'
    if (-not $NoOpen) { Open-Dashboard }
    exit 0
}
Remove-Item -LiteralPath (Join-Path $Data 'tray_stop') -Force -ErrorAction SilentlyContinue   # left by a stop with no tray

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$Python = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
if (-not $Python) { $Python = 'python' }
$script:ServerProc = $null; $script:FetcherProc = $null
$script:ServerKillAt = $null; $script:FetcherKillAt = $null
$script:LastState = $null; $script:PageOpened = [bool]$NoOpen; $script:Quitting = $false

function Test-Alive($Proc) { return ($null -ne $Proc -and -not $Proc.HasExited) }
function Test-FetcherUp { return ((Test-Alive $script:FetcherProc) -or (Test-LockHeld $LockPath)) }

function Start-Child([string]$Script, [string[]]$More) {
    $argList = @('"' + (Join-Path $Dash $Script) + '"') + $More
    return Start-Process -FilePath $Python -ArgumentList $argList -WorkingDirectory $Root -WindowStyle Hidden -PassThru
}

function Start-LiveServer {
    if (Test-ServerUp $Port) { Log "live server already answering on port $Port"; return }
    $script:ServerProc = Start-Child 'server.py' @('--no-open', '--port', "$Port")
    $script:ServerKillAt = $null
    Log "live server started (pid $($script:ServerProc.Id))"
}

function Stop-LiveServer {
    if (Send-ServerStop $Port) { Log 'live server asked to stop' }
    if (Test-Alive $script:ServerProc) { $script:ServerKillAt = (Get-Date).AddSeconds(10) }
}

function Start-Fetcher {
    $cfg = Read-LedgerConfig (Join-Path $Root 'ledger.cfg')
    if (-not $cfg['bnet_id']) { Log 'AH fetcher not set up (no bnet_id in ledger.cfg)'; return }
    if (Test-FetcherUp) { Log 'AH fetcher already running'; return }
    # a stop flag left from when nothing was running would end the new fetcher after its first fetch
    Remove-Item -LiteralPath (Join-Path $Data 'fetcher_stop') -Force -ErrorAction SilentlyContinue
    $script:FetcherProc = Start-Child 'fetcher.py' @()
    $script:FetcherKillAt = $null
    Log "AH fetcher started (pid $($script:FetcherProc.Id))"
}

function Stop-Fetcher {
    if (Test-FetcherUp) {
        [IO.File]::WriteAllText((Join-Path $Data 'fetcher_stop'), '')
        Log 'AH fetcher asked to stop'
    }
    if (Test-Alive $script:FetcherProc) { $script:FetcherKillAt = (Get-Date).AddSeconds(10) }
}

function Request-Fetch {
    [IO.File]::WriteAllText((Join-Path $Data 'fetch_now'), '')
    Log 'fetch now requested'
}

function Stop-Children {
    # ask both, wait up to 10 s, then end whichever of ours is still there
    Stop-LiveServer
    Stop-Fetcher
    $until = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $until -and ((Test-Alive $script:ServerProc) -or (Test-Alive $script:FetcherProc))) {
        Start-Sleep -Milliseconds 250
    }
    foreach ($p in @($script:ServerProc, $script:FetcherProc)) {
        if (Test-Alive $p) { Log "pid $($p.Id) didn't stop within 10 s: ending it" 'WARNING'; $p.Kill() }
    }
}

function New-DotIcon([string]$Hex) {
    $bmp = New-Object Drawing.Bitmap 16, 16
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($Hex))
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $brush.Dispose(); $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$Icons = @{ green = (New-DotIcon '#2e9d5b'); amber = (New-DotIcon '#e0a030'); grey = (New-DotIcon '#8a8a8a') }

$Notify = New-Object Windows.Forms.NotifyIcon
$Notify.Icon = $Icons.grey
$Notify.Text = 'Adventure Ledger: starting'
$Menu = New-Object Windows.Forms.ContextMenuStrip
function Add-MenuItem($Items, [string]$Text, [scriptblock]$Action) {
    $item = New-Object Windows.Forms.ToolStripMenuItem $Text
    $item.Tag = $Action
    $item.add_Click({
        param($item)
        try { & $item.Tag } catch { Log "$($item.Text) failed: $_" 'ERROR' }
        Update-Tray
    })
    [void]$Items.Add($item)
    return $item
}

[void](Add-MenuItem $Menu.Items 'Open dashboard' { Open-Dashboard })
$miLive = New-Object Windows.Forms.ToolStripMenuItem 'Live server'
[void]$Menu.Items.Add($miLive)
$miLiveStart = Add-MenuItem $miLive.DropDownItems 'Start' { Start-LiveServer }
$miLiveStop = Add-MenuItem $miLive.DropDownItems 'Stop' { Stop-LiveServer }
$miAh = New-Object Windows.Forms.ToolStripMenuItem 'AH fetcher'
[void]$Menu.Items.Add($miAh)
$miAhStart = Add-MenuItem $miAh.DropDownItems 'Start' { Start-Fetcher }
$miAhStop = Add-MenuItem $miAh.DropDownItems 'Stop' { Stop-Fetcher }
$miAhNow = Add-MenuItem $miAh.DropDownItems 'Fetch now' { Request-Fetch }
[void](Add-MenuItem $Menu.Items 'Open logs folder' { Start-Process explorer.exe "`"$Data`"" })
$miBoot = Add-MenuItem $Menu.Items 'Start with Windows' {
    if (Test-Path -LiteralPath (Get-StartupLinkPath)) { Remove-StartupLink; Log 'start with Windows: off' }
    else { New-StartupLink; Log 'start with Windows: on' }
}
[void]$Menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem $Menu.Items 'Quit' { Exit-Tray 'quit from the menu' })
$Notify.ContextMenuStrip = $Menu
$Notify.add_DoubleClick({ try { Open-Dashboard } catch { Log "open failed: $_" 'ERROR' } })

$Menu.add_Opening({
    # enable what makes sense right now
    try {
        $serverUp = Test-ServerUp $Port
        $fetcherUp = Test-FetcherUp
        $cfg = Read-LedgerConfig (Join-Path $Root 'ledger.cfg')
        $notSetUp = Test-NotSetUp $cfg (Read-FetcherStatus $StatusPath) $fetcherUp
        $miLiveStart.Enabled = -not $serverUp
        $miLiveStop.Enabled = $serverUp
        $miAhStart.Enabled = (-not $notSetUp) -and (-not $fetcherUp)
        $miAhStop.Enabled = (-not $notSetUp) -and $fetcherUp
        $miAhNow.Enabled = (-not $notSetUp) -and $fetcherUp
        $miAh.Text = if ($notSetUp) { 'AH fetcher (not set up)' } else { 'AH fetcher' }
        $miBoot.Checked = Test-Path -LiteralPath (Get-StartupLinkPath)
    } catch { Log "menu: $_" 'ERROR' }
})

function Update-Tray {
    if ($script:Quitting) { return }
    if (Test-Path -LiteralPath (Join-Path $Data 'tray_stop')) {
        Remove-Item -LiteralPath (Join-Path $Data 'tray_stop') -Force -ErrorAction SilentlyContinue
        Exit-Tray 'wowstats stop'
        return
    }
    $now = Get-Date
    if ($script:ServerKillAt -and $now -gt $script:ServerKillAt) {
        if (Test-Alive $script:ServerProc) { Log "live server didn't stop within 10 s: ending it" 'WARNING'; $script:ServerProc.Kill() }
        $script:ServerKillAt = $null
    }
    if ($script:FetcherKillAt -and $now -gt $script:FetcherKillAt) {
        if (Test-Alive $script:FetcherProc) { Log "AH fetcher didn't stop within 10 s: ending it" 'WARNING'; $script:FetcherProc.Kill() }
        $script:FetcherKillAt = $null
    }

    $serverUp = Test-ServerUp $Port
    $fetcherUp = Test-FetcherUp
    $status = Read-FetcherStatus $StatusPath
    $cfg = Read-LedgerConfig (Join-Path $Root 'ledger.cfg')
    $every = 60
    [void][int]::TryParse([string]$cfg['ah_every'], [ref]$every)
    if ($every -le 0) { $every = 60 }
    $state = Get-TrayState -ServerUp $serverUp -ServerProcAlive (Test-Alive $script:ServerProc) -FetcherUp $fetcherUp `
        -NotSetUp (Test-NotSetUp $cfg $status $fetcherUp) -Status $status -EveryMin $every
    if (-not $script:LastState -or $state.Colour -ne $script:LastState.Colour -or $state.Tip -ne $script:LastState.Tip) {
        Log "$($state.Colour): $($state.Tip)"
        $Notify.Icon = $Icons[$state.Colour]
        $Notify.Text = $state.Tip
        $script:LastState = $state
    }
    if ($serverUp -and -not $script:PageOpened) {
        $script:PageOpened = $true
        Start-Process "http://127.0.0.1:$Port/"
    }
}

$Context = New-Object Windows.Forms.ApplicationContext
function Exit-Tray([string]$Reason) {
    if ($script:Quitting) { return }
    $script:Quitting = $true
    $Timer.Stop()
    Log "stopping ($Reason)"
    Stop-Children
    $Notify.Visible = $false
    $Notify.Dispose()
    Log 'stopped'
    $Context.ExitThread()
}

$Timer = New-Object Windows.Forms.Timer
$Timer.Interval = 5000
$Timer.add_Tick({ try { Update-Tray } catch { Log "tick: $_" 'ERROR' } })

Log "started (pid $PID, port $Port, data $Data)"
Start-LiveServer
Start-Fetcher
$Notify.Visible = $true
$Timer.Start()
# a first look soon after start, so the icon and the page don't wait a whole tick
$First = New-Object Windows.Forms.Timer
$First.Interval = 1500
$First.add_Tick({ $First.Stop(); try { Update-Tray } catch { Log "tick: $_" 'ERROR' } })
$First.Start()
[Windows.Forms.Application]::Run($Context)
$Mutex.ReleaseMutex()
$Mutex.Dispose()
