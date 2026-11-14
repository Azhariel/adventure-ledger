<#
.SYNOPSIS
  Installs the Adventure Ledger addons into WoW Forever and sets up the dashboard.

.DESCRIPTION
  Copies every addon in .\addons into <WoW>\Interface\AddOns (leaving out tests and dev tools), writes ledger.cfg
  so the dashboard knows where WoW is, and checks for the third-party addons the dashboard reads.
  Run it again after pulling a new version: it replaces the old copies. An addon folder it replaces is backed up
  to data\addon-backups first. Your SavedVariables (WTF folder) are never touched.

.PARAMETER Wow
  The WoW Forever folder (the one with Interface, WTF and Logs). Found on its own when left out.

.PARAMETER Dev
  Link the addons instead of copying them (directory junctions), so WoW runs the repo's files. For working on
  the addons themselves.

.PARAMETER Copy
  Replace addons that are linked to this repo (a -Dev setup) with plain copies. Without it, links are left alone.

.EXAMPLE
  .\install.bat
  .\install.bat -Wow "D:\Games\World of Warcraft\_forever_"
  .\install.bat -Dev
#>
param(
    [string]$Wow,
    [switch]$Dev,
    [switch]$Copy
)
$ErrorActionPreference = "Stop"
$Repo = $PSScriptRoot
$Source = Join-Path $Repo "addons"
$Cfg = Join-Path $Repo "ledger.cfg"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function IsWow($path) { $path -and (Test-Path (Join-Path $path "Interface")) -and (Test-Path (Join-Path $path "WTF")) }

# ---------------------------------------------------------------- where WoW is
function FindWow {
    if ($Wow) { return $Wow }
    if (Test-Path $Cfg) {
        $line = Get-Content $Cfg | Where-Object { $_ -match '^\s*wow\s*=' } | Select-Object -First 1
        if ($line) { return ($line -replace '^\s*wow\s*=\s*', '').Trim() }
    }
    $candidates = @()
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft', 'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
        try {
            $p = (Get-ItemProperty $key -ErrorAction Stop).InstallPath
            if ($p) { $candidates += (Join-Path (Split-Path ($p.TrimEnd('\')) -Parent) "_forever_") }
        } catch {}
    }
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles) + (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
        if ($root) { $candidates += (Join-Path $root "World of Warcraft\_forever_") }
    }
    foreach ($c in $candidates) { if (IsWow $c) { return $c } }
    return $null
}

$Wow = FindWow
if (-not (IsWow $Wow)) {
    if ($Wow) { Say "No WoW folder at $Wow (it needs Interface and WTF inside)." Yellow }
    $Wow = Read-Host "Where is WoW Forever? Paste the _forever_ folder (the one with Interface and WTF)"
    $Wow = $Wow.Trim('"', ' ')
    if (-not (IsWow $Wow)) { Say "That folder doesn't have Interface and WTF in it. Nothing was installed." Red; exit 1 }
}
$Wow = (Resolve-Path $Wow).Path
$AddOns = Join-Path $Wow "Interface\AddOns"
Say "WoW Forever: $Wow" Cyan

# ---------------------------------------------------------------- the addons
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $Repo "data\addon-backups\$stamp"
$names = Get-ChildItem $Source -Directory | Where-Object { Test-Path (Join-Path $_.FullName "$($_.Name).toc") }
foreach ($a in $names) {
    $dest = Join-Path $AddOns $a.Name
    $item = Get-Item $dest -ErrorAction SilentlyContinue
    $linkedHere = $item -and $item.LinkType -and ((@($item.Target) -join "") -eq $a.FullName)
    if ($Dev -and $linkedHere) { Say ("  {0,-12} linked already" -f $a.Name); continue }
    # A dev setup (linked to this repo) stays linked: copying over it would quietly cut WoW off from your edits
    if ($linkedHere -and -not $Copy) { Say ("  {0,-12} linked to this repo (dev setup): left as is; -Copy replaces it with a copy" -f $a.Name); continue }
    if ($item) {
        if ($item.LinkType) {
            $item.Delete()   # a link: drop it, never what it points to
        } else {
            New-Item -ItemType Directory -Force $backupRoot | Out-Null
            Move-Item $dest (Join-Path $backupRoot $a.Name)
        }
    }
    if ($Dev) {
        New-Item -ItemType Junction -Path $dest -Target $a.FullName | Out-Null
        Say ("  {0,-12} linked to the repo" -f $a.Name) Green
    } else {
        robocopy $a.FullName $dest /E /XD tests tools /XF *.stackdump /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Say "  copying $($a.Name) failed (robocopy $LASTEXITCODE)" Red; exit 1 }
        $version = (Select-String -Path (Join-Path $a.FullName "$($a.Name).toc") -Pattern '^## Version:\s*(.+)$').Matches.Groups[1].Value
        Say ("  {0,-12} {1}" -f $a.Name, $version) Green
    }
}
if (Test-Path $backupRoot) { Say "Replaced folders were backed up to $backupRoot" }

# ---------------------------------------------------------------- the dashboard's settings
if (-not (Test-Path $Cfg)) {
    "# Written by install.ps1. See ledger.cfg.example.`r`nwow = $Wow`r`n" | Set-Content -Path $Cfg -Encoding ascii -NoNewline
    Say "Wrote ledger.cfg (wow = $Wow)"
}

# ---------------------------------------------------------------- what else the dashboard reads
Say "`nOther addons the dashboard reads (install them yourself; they aren't ours to share):" Cyan
$others = @(
    @{ Name = "Auctionator"; Why = "auction house prices (the whole Market section)"; Where = "https://www.curseforge.com/wow/addons/auctionator" },
    @{ Name = "MuddyBoots"; Why = "optional: only your history from before Logbook (Logbook records the rest)"; Where = "from its author, Mookz" },
    @{ Name = "QuestieDB"; Why = "item names"; Where = "from the Questie project" }
)
foreach ($o in $others) {
    if (Test-Path (Join-Path $AddOns $o.Name)) { Say ("  {0,-12} found" -f $o.Name) Green }
    else { Say ("  {0,-12} missing: {1}. Get it {2}" -f $o.Name, $o.Why, $o.Where) Yellow }
}

# ---------------------------------------------------------------- next steps
$lua = (Test-Path (Join-Path $env:LOCALAPPDATA "Programs\Lua\bin\lua.exe")) -or (Get-Command lua -ErrorAction SilentlyContinue)
Say "`nNext:" Cyan
if (Get-Process -Name Wow -ErrorAction SilentlyContinue) { Say "  WoW is running: type /reload so it loads the new addons." }
if (-not $lua) { Say "  Install Lua 5.4 to build the dashboard (https://www.lua.org/download.html)." Yellow }
Say "  Play, then /reload or log out, and run dashboard\build.bat (or bin\wowstats.bat) to build your page."
