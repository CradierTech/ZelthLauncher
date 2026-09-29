<#
.SYNOPSIS
    Windows regression suite for the Zelth installer. Mirrors selftest.sh.

.DESCRIPTION
    Fetches install.ps1 from the published repo and exercises it the way a real
    user would, then asserts the result. Run this INSIDE the Windows VM:

        irm https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/selftest.ps1 | iex

    Needs a real (non-empty) token? No - everything it downloads is public.
    It WILL download ~300 MB and install Electron on the first real run.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'CradierTech/ZelthLauncher',
    [switch]$SkipRealInstall,
    [switch]$SkipOneLiner
)

$ErrorActionPreference = 'Stop'

# Stock Windows PowerShell ships ExecutionPolicy=Restricted, which blocks
# invoking a downloaded .ps1 from disk. This harness is itself run via
# `irm | iex` (in memory, so allowed) but then calls install.ps1 as a file.
# Process-scoped, no admin rights, disappears when the window closes.
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
    Write-Host '  (execution policy bypassed for this session)' -ForegroundColor DarkGray
} catch {
    Write-Host '  WARNING: could not relax ExecutionPolicy for this session.' -ForegroundColor Yellow
    Write-Host '  If the installer cannot be invoked, re-run from an elevated PowerShell.' -ForegroundColor Yellow
}

$Base = "https://raw.githubusercontent.com/$Repo/main/installer"
$Work = Join-Path $env:TEMP ("zelth-wintest-" + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $Work -Force | Out-Null

$script:Pass = 0
$script:Fail = 0
$Lines = New-Object System.Collections.ArrayList

function Chk([bool]$cond, [string]$name, [string]$detail = '') {
    if ($cond) {
        $script:Pass++
        [void]$Lines.Add("  PASS  $name")
        Write-Host "  PASS  $name" -ForegroundColor DarkCyan
    } else {
        $script:Fail++
        $msg = "  FAIL  $name$(if($detail){"  -- $detail"})"
        [void]$Lines.Add($msg)
        Write-Host $msg -ForegroundColor Red
    }
}
function Hdr([string]$t) { Write-Host ''; Write-Host "-- $t --" -ForegroundColor White }

Write-Host ''
Write-Host '  Zelth Windows installer test suite' -ForegroundColor Magenta
Write-Host "  repo: $Repo" -ForegroundColor DarkGray
Write-Host "  work: $Work" -ForegroundColor DarkGray

# ---------------------------------------------------------------- static ----
Hdr 'static'
$ps1 = Join-Path $Work 'install.ps1'
try {
    Invoke-WebRequest -Uri "$Base/install.ps1" -OutFile $ps1 -UseBasicParsing -ErrorAction Stop
    Chk $true 'install.ps1 downloaded from raw.githubusercontent'
} catch {
    Chk $false 'install.ps1 downloaded from raw.githubusercontent' $_.Exception.Message
    Write-Host "`nCannot continue without the installer." -ForegroundColor Red
    return
}
$src = Get-Content $ps1 -Raw
Chk ($src.Length -gt 20000) 'install.ps1 is non-trivial' "len=$($src.Length)"
Chk ($src -match 'param\s*\(') 'has a param block'
foreach ($sw in 'NoLaunch','DryRun','Force','NoElectron','NoDesktopShortcut','NoPreserveSaves') {
    Chk ($src -match "\`$$sw") "declares -$sw"
}
# PowerShell 7 only syntax would break on the stock 5.1 shell
Chk ($src -notmatch '(?m)^\s*if\s*\(.+\)\s*\{[^}]*\}\s*&&\s*') 'no PS7-only && operator'
Chk ($src -notmatch '\?\?') 'no PS7-only ?? operator'
Chk ($src -match 'Expand-Archive') 'extracts with Expand-Archive'
Chk ($src -match 'Get-FileHash') 'verifies with Get-FileHash'
Chk ($src -match 'WScript\.Shell') 'creates shortcuts with WScript.Shell'

# -------------------------------------------------------------- dry run ----
Hdr 'dry run leaves no trace'
$probe = Join-Path $Work 'probe'
New-Item -ItemType Directory -Path $probe -Force | Out-Null
$before = @(Get-ChildItem $probe -Recurse -Force -ErrorAction SilentlyContinue).Count
try {
    & $ps1 -DryRun -InstallDir (Join-Path $probe 'zelth') -NoElectron -NoDesktopShortcut -Force *>&1 |
        Out-Null
    Chk $true 'dry run exits 0'
} catch {
    Chk $false 'dry run exits 0' $_.Exception.Message
}
$after = @(Get-ChildItem $probe -Recurse -Force -ErrorAction SilentlyContinue).Count
Chk ($after -eq $before) 'dry run wrote nothing' "before=$before after=$after"

if ($SkipRealInstall) {
    Write-Host "`nSkipping the real install (-SkipRealInstall)." -ForegroundColor Yellow
} else {
    # ------------------------------------------------------- real install ----
    Hdr 'real install'
    $dir = Join-Path $env:LOCALAPPDATA 'Zelth'
    if (Test-Path $dir) {
        Write-Host "  (an install already exists at $dir - it will be replaced)" -ForegroundColor DarkGray
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $ps1 -InstallDir $dir -NoLaunch -Force *>&1 | Out-Null
        Chk $true 'install exits 0'
    } catch {
        Chk $false 'install exits 0' $_.Exception.Message
    }
    $sw.Stop()
    Write-Host ("  took {0:N0}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    Chk (Test-Path (Join-Path $dir 'package.json')) 'package.json installed'
    foreach ($f in 'main.js','preload.js','renderer.js','launcher.js','index.html','styles.css','zelth.cmd') {
        Chk (Test-Path (Join-Path $dir $f)) "$f installed"
    }
    foreach ($f in 'zelth-meteor-config.nbt','zelth-meteor-theme.nbt','zelth.png') {
        Chk (Test-Path (Join-Path $dir $f)) "$f present (Meteor masters)"
    }
    Chk (Test-Path (Join-Path $dir 'uninstall.ps1')) 'uninstaller written'
    Chk (-not (Test-Path (Join-Path $dir 'node_modules\..\installer'))) 'no installer/ leaked into the app dir'

    # ---- electron ----
    $exe = Join-Path $dir 'node_modules\electron\dist\electron.exe'
    Chk (Test-Path $exe) 'electron.exe present'
    if (Test-Path $exe) {
        try {
            $v = (& $exe --version 2>&1 | Select-Object -First 1).ToString().Trim()
            Chk ($v -match '^v?33\.') "electron runs ($v)" "unexpected version"
        } catch { Chk $false 'electron runs' $_.Exception.Message }
    }
    $idx = Join-Path $dir 'node_modules\electron\index.js'
    Chk (Test-Path $idx) 'electron index.js present (node resolution)'
    if (Test-Path $idx) {
        $i = Get-Content $idx -Raw
        Chk ($i -match 'electron\.exe') 'index.js points at electron.exe'
    }

    # ---- java ----
    $java = Join-Path $dir 'game\runtime\java-runtime-delta\windows\java-runtime-delta\bin\java.exe'
    Chk (Test-Path $java) 'windows JRE (java.exe) present'
    if (Test-Path $java) {
        try {
            $jv = (& $java -version 2>&1 | Select-Object -First 1).ToString()
            Chk ($jv -match '"21\.') "java runs ($($jv -replace '.*version ',' '))"
        } catch { Chk $false 'java runs' $_.Exception.Message }
    }
    Chk (-not (Test-Path (Join-Path $dir 'game\runtime\java-runtime-delta\linux'))) 'no linux JRE shipped (right bundle)'

    # ---- game ----
    $vers = Join-Path $dir 'game\versions'
    Chk (Test-Path $vers) 'game/versions present'
    if (Test-Path $vers) {
        foreach ($v in 'zelth Cheats 1.21.11 Fabric','zelth Prime 1.21.11 fabric') {
            Chk (Test-Path (Join-Path $vers $v)) "game version: $v"
        }
    }
    Chk (Test-Path (Join-Path $dir 'game\libraries')) 'game/libraries present'

    # ---- shortcuts ----
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desk 'Zelth.lnk'
    Chk (Test-Path $lnk) "Desktop shortcut created ($lnk)"
    if (Test-Path $lnk) {
        try {
            $sh = New-Object -ComObject WScript.Shell
            $s = $sh.CreateShortcut($lnk)
            Chk (Test-Path $s.TargetPath) "shortcut target resolves ($($s.TargetPath))"
            Chk ($s.TargetPath -like '*zelth.cmd') 'shortcut points at zelth.cmd'
        } catch { Chk $false 'shortcut is readable' $_.Exception.Message }
    }
    $start = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Zelth.lnk'
    Chk (Test-Path $start) 'Start Menu shortcut created'

    # ---- dev junk must not be there ----
    foreach ($j in 'CHEATS.md','install.bin','zelth.bin','zelthpack','zelth_theme.py') {
        Chk (-not (Test-Path (Join-Path $dir $j))) "no dev junk: $j"
    }

    # ---- saves survive an upgrade ----
    Hdr 'saves survive an upgrade'
    $sv = $null
    foreach ($vd in (Get-ChildItem (Join-Path $vers '*') -Directory -ErrorAction SilentlyContinue)) {
        $p = Join-Path $vd.FullName 'saves\TestWorld\level.dat'
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        Set-Content -Path $p -Value 'REALWORLD'
        $sv = $p
        break
    }
    Chk ($null -ne $sv) 'created a test world'
    if ($sv) {
        try { & $ps1 -InstallDir $dir -NoLaunch -Force *>&1 | Out-Null; Chk $true 'upgrade exits 0' } catch { Chk $false 'upgrade exits 0' $_.Exception.Message }
        Chk (Test-Path $sv) 'test world survived the upgrade'
        if (Test-Path $sv) { Chk ((Get-Content $sv -Raw).Trim() -eq 'REALWORLD') 'test world contents intact' }
    }
}

# ------------------------------------------------------------ one-liner ----
if (-not $SkipOneLiner) {
    Hdr 'the literal one-liner a user pastes'
    try {
        $code = (Invoke-WebRequest -Uri "$Base/install.sh" -UseBasicParsing -ErrorAction Stop).Content
        Chk $true 'install.sh is also served (for the Linux path)'
    } catch { Chk $false 'install.sh served' $_.Exception.Message }
    Write-Host '  note: the real one-liner auto-launches the app.' -ForegroundColor DarkGray
    Write-Host '  run it manually if you want to see the window:' -ForegroundColor DarkGray
    Write-Host "    irm $Base/install.ps1 | iex" -ForegroundColor DarkYellow
}

# ----------------------------------------------------------------- report ----
$total = $script:Pass + $script:Fail
Write-Host ''
if ($script:Fail -eq 0) {
    $head = "$total passed, 0 failed"
    Write-Host "  $head" -ForegroundColor Cyan
} else {
    $head = "$total passed, $($script:Fail) FAILED"
    Write-Host "  $head" -ForegroundColor Red
}
$report = @"
Zelth Windows test suite  ($([DateTime]::Now.ToString('s')))
$head
$($Lines -join "`n")
"@
Write-Host ''
Write-Host '  report copied to clipboard - paste it back to get help' -ForegroundColor DarkGray
try { Set-Clipboard -Value $report } catch { }
Write-Host ''
Write-Host $head -ForegroundColor $(if ($script:Fail -eq 0) { 'Cyan' } else { 'Red' })

Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
if ($script:Fail -gt 0) { exit 1 }
