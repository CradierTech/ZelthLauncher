<#
.SYNOPSIS
    Zelth Launcher - one-shot installer for Windows.

.DESCRIPTION
    Installs the Zelth launcher and its bundled game into %LOCALAPPDATA%\Zelth.
    Needs nothing preinstalled: no Node.js, no npm, no Electron, no Java.
    Everything lands under the user profile, so no administrator rights.

    Mirrors installer/install.sh on Linux. Same bundle, same manifest,
    same checksums, same update flow.

.PARAMETER NoLaunch
    Do not start the launcher when the install finishes.

.PARAMETER NoElectron
    Skip the Electron runtime (the app files are still installed).

.PARAMETER NoDesktopShortcut
    Do not create the Desktop / Start Menu shortcuts.

.PARAMETER Force
    Overwrite an existing install without asking.

.PARAMETER DryRun
    Print the plan and change nothing.

.EXAMPLE
    irm https://raw.githubusercontent.com/CradierTech/ZelthLauncher/main/installer/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$NoElectron,
    [switch]$NoDesktopShortcut,
    [switch]$NoPreserveSaves,
    [switch]$Force,
    [switch]$DryRun,
    [string]$Channel = 'stable',
    [string]$Repo = 'CradierTech/ZelthLauncher',
    [string]$InstallDir,
    [string]$ElectronVersion = '',
    [string]$BundleName = '',
    [ValidateSet('en','pt')][string]$Lang = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- config ----
$script:ZelthVersion = '3.1.0'
$script:ElectronDefault = '33.4.11'
$script:BundleDefault  = 'zelth-latest-windows.zip'
$script:FallbackBundle = 'zelth-latest.tar.gz'
$script:AppName = 'Zelth'
$script:AppId   = 'Zelth'

if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Zelth' }
if (-not $BundleName) { $BundleName = $script:BundleDefault }
if (-not $ElectronVersion) { $ElectronVersion = $script:ElectronDefault }

# ------------------------------------------------------------- bilingual ----
if (-not $Lang) {
    $sys = (Get-Culture).Name
    if ($sys -like 'pt*') { $Lang = 'pt' } else { $Lang = 'en' }
}
$script:Lang = $Lang

function T {
    param([string]$En, [string]$Pt)
    if ($Lang -eq 'pt') { return $Pt } else { return $En }
}

# ---------------------------------------------------------------- colours ---
$script:UseColor = $true
if ($env:NO_COLOR) { $script:UseColor = $false }

function Paint([string]$code, [string]$text) {
    if (-not $script:UseColor) { return $text }
    return "$code$text$([char]27 + '[0m')"
}
function Section { param([string]$m) Write-Host ''; Write-Host (Paint ([char]27 + '[1;36m') ("== " + $m + " ==")) }
function Step    { param([string]$m) Write-Host (Paint ([char]27 + '[33m') ('-> ')) -NoNewline; Write-Host $m }
function Ok      { param([string]$m) Write-Host (Paint ([char]27 + '[32m') '  [ok] ') -NoNewline; Write-Host $m }
function Have    { param([string]$m) Write-Host (Paint ([char]27 + '[36m') '  [+] ') -NoNewline; Write-Host $m }
function Warn    { param([string]$m) Write-Host (Paint ([char]27 + '[33m') '  [!] ') -NoNewline; Write-Host $m }
function Skip    { param([string]$m) Write-Host (Paint ([char]27 + '[90m') ('  [.] ' + $m)) }
function Die     { param([string]$m) Write-Host ''; Write-Host (Paint ([char]27 + '[31m') ('error: ' + $m)) -ForegroundColor Red; exit 1 }

function HumanSize([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N1} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

function Confirm([string]$prompt) {
    if ($Force) { return $true }
    if (-not [Environment]::UserInteractive) { return $true }
    $a = (T 'Y/n' 'S/n')
    $r = Read-Host ("  " + $prompt + " [$a]")
    if ([string]::IsNullOrWhiteSpace($r)) { return $true }
    return ($r -match '^[YySs]')
}

# ------------------------------------------------------------------ banner --
function Banner {
    Write-Host ''
    Write-Host (Paint ([char]27 + '[1;35m') '  (  ...  )') -ForegroundColor Magenta
    Write-Host (Paint ([char]27 + '[1;35m') '   ( o o )') -ForegroundColor Magenta
    Write-Host (Paint ([char]27 + '[1;35m') '    (   )') -ForegroundColor Magenta
    Write-Host (Paint ([char]27 + '[1;33m') '   ZELTH  installer for Windows') -ForegroundColor Yellow
    Write-Host (Paint ([char]27 + '[90m') ("  v$script:ZelthVersion")) -ForegroundColor DarkGray
}

# =========================================================== pre-flight ====
Section (T 'PRE-FLIGHT' 'VERIFICACAO INICIAL')

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Die (T 'PowerShell 5.1 or newer is required.' 'PowerShell 5.1 ou mais novo e necessario.')
}

# 32-bit PowerShell on 64-bit Windows cannot run x64 Electron properly.
$is64 = [Environment]::Is64BitOperatingSystem
$proc64 = [Environment]::Is64BitProcess
if ($is64 -and -not $proc64) {
    Die (T 'You are running 32-bit PowerShell on 64-bit Windows. Run PowerShell as x64 and retry.' 'Voce esta usando PowerShell de 32 bits em Windows de 64 bits. Use o PowerShell x64 e tente de novo.')
}
$Arch = if ($env:PROCESSOR_ARCHITEW6432) { 'arm64' } elseif ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
Have (T 'Architecture' 'Arquitetura') "Windows $Arch"

$drive = (Split-Path -Qualifier $InstallDir).TrimEnd(':')
$free = $null
try { $free = (Get-PSDrive -Name $drive.TrimEnd('\') -ErrorAction Stop).Free } catch { }
if ($null -ne $free) {
    $need = 1.2GB
    if ($free -lt $need) { Die (T ("Not enough disk space: {0} free, need 1.2 GB" -f (HumanSize $free)) ("Espaco insuficiente: {0} livres, precisa de 1.2 GB" -f (HumanSize $free))) }
    Have (T 'Disk' 'Disco') ((T 'free' 'livres') + ' ' + (HumanSize $free))
}

$existing = Test-Path -LiteralPath $InstallDir
if ($existing -and -not $DryRun) {
    Warn (T "Existing installation found: $InstallDir" "Instalacao existente encontrada: $InstallDir")
    if (-not (Confirm (T 'Overwrite it?' 'Sobrescrever?'))) { Die (T 'Aborted by user' 'Cancelado pelo usuario') }
}

# ============================================================== download ====
function ResolveDistUrl {
    switch ($Channel) {
        'stable' { return "https://github.com/$Repo/releases/latest/download" }
        'beta'   { return "https://github.com/$Repo/releases/download/beta" }
        'nightly'{ return "https://github.com/$Repo/releases/download/nightly" }
        default  { return $Channel }
    }
}

$DistUrl = ResolveDistUrl
$TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("zelth-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
$PrevDir = "$InstallDir.prev"

function Cleanup { param($keepPrev) if (Test-Path $TmpDir) { Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue } }

function Get-File([string]$url, [string]$out) {
    try {
        if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) {
            Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
        } else {
            Invoke-RestMethod -Uri $url -OutFile $out -MaximumRedirection 10 -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

Section (T 'BUNDLE' 'PACOTE')

$cacheDir = Join-Path $env:LOCALAPPDATA 'zelth-cache'
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

# --- manifest (optional) ---
$manifest = $null
$mfPath = Join-Path $TmpDir 'manifest.json'
if (Get-File "$DistUrl/manifest.json" $mfPath) {
    try {
        $manifest = Get-Content $mfPath -Raw | ConvertFrom-Json
        if ($manifest.version) { $script:ZelthVersion = $manifest.version; Have "version $($manifest.version)" }
        if ($manifest.electron) { $ElectronVersion = $manifest.electron; Have "electron $($manifest.electron)" }
        # prefer the windows-specific build, fall back to the combined bundle
        $pick = $null
        if ($manifest.windows) { $pick = $manifest.windows }
        elseif ($manifest.bundle) { $pick = $manifest.bundle }
        if ($pick) { $BundleName = $pick; Have "bundle $BundleName" }
    } catch { Skip (T 'manifest unreadable, using defaults' 'manifesto ilegivel, usando padroes') }
} else {
    Skip (T 'manifest.json not available, using defaults' 'manifesto nao disponivel, usando padroes')
}

# --- resolve the bundle: prefer the platform build, fall back to combined ---
if (-not $manifest -or -not $BundleName) { $BundleName = $script:BundleDefault }
$candidates = @($BundleName)
if ($candidates -notcontains $script:FallbackBundle) { $candidates += $script:FallbackBundle }

$tarball = $null
foreach ($cand in $candidates) {
    $cachePath = Join-Path $cacheDir $cand
    Step (T "Trying" "Tentando") $cand
    if ((Test-Path $cachePath)) {
        $tarball = $cachePath
        Have (T "using cached" "usando cache") $cand
        break
    }
    $out = Join-Path $TmpDir $cand
    if (Get-File "$DistUrl/$cand" $out) {
        $tarball = $out
        Have (T "downloaded" "baixado") ("$cand (" + (HumanSize (Get-Item $out).Length) + ")")
        break
    }
    Skip (T "not available" "indisponivel") $cand
}
if (-not $tarball) { Die (T 'Could not download the Zelth bundle.' 'Nao foi possivel baixar o pacote do Zelth.') }

# --- checksum ---
$sumsPath = Join-Path $TmpDir 'SHA256SUMS'
if (Get-File "$DistUrl/SHA256SUMS" $sumsPath) {
    $line = Select-String -Path $sumsPath -Pattern ([regex]::Escape((Split-Path -Leaf $tarball)) + '$') | Select-Object -First 1
    if ($line) {
        $want = ($line.Line -split '\s+')[0].ToLower()
        $got  = (Get-FileHash -Path $tarball -Algorithm SHA256).Hash.ToLower()
        if ($want -ne $got) {
            Remove-Item -Force $tarball -ErrorAction SilentlyContinue
            Die (T 'Checksum mismatch - the download was corrupted. Nothing installed.' 'Soma de verificacao diferente - o download estava corrompido. Nada foi instalado.')
        }
        Have (T 'checksum verified' 'soma verificada') $got.Substring(0,16)
    }
} else {
    Warn (T 'SHA256SUMS not available - skipping verification' 'SHA256SUMS indisponivel - pulando verificacao')
}

# --- cache the verified tarball ---
$cachePath = Join-Path $cacheDir (Split-Path -Leaf $tarball)
if ((Split-Path -Parent $tarball) -ne $cacheDir) {
    try { Copy-Item $tarball $cachePath -Force -ErrorAction Stop; Have (T 'cached for next time' 'guardado em cache') $cachePath } catch { }
}

# ================================================================ extract ===
Section (T 'FILES' 'ARQUIVOS')

if ($DryRun) {
    Skip (T '[dry-run] would extract' '[dry-run] extrairia') (Split-Path -Leaf $tarball)
    Skip (T '[dry-run] would install into' '[dry-run] instalaria em') $InstallDir
} else {
    if (Test-Path $InstallDir) {
        Step (T 'Backing up to' 'Fazendo backup em') $PrevDir
        if (Test-Path $PrevDir) { Remove-Item -Recurse -Force $PrevDir -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $InstallDir -Destination $PrevDir -Force
        Ok (T 'Previous install saved' 'Instalacao anterior salva') $PrevDir
    }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    $stage = Join-Path $TmpDir 'stage'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Expand-Archive -Path $tarball -DestinationPath $stage -Force -ErrorAction Stop
    } catch {
        Die (T 'Extraction failed.' 'Falha ao extrair.')
    }

    # bsdtar-style archives wrap everything in one top-level dir; flatten it
    $pkg = Join-Path $stage 'package.json'
    if (-not (Test-Path $pkg)) {
        $sub = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
        if ($sub -and (Test-Path (Join-Path $sub.FullName 'package.json'))) { $stage = $sub.FullName }
    }
    if (-not (Test-Path (Join-Path $stage 'package.json'))) { Die (T 'Bundle has no package.json' 'Pacote sem package.json') }

    Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    # dotfiles are skipped by the wildcard above
    Get-ChildItem -Path $stage -Force | Where-Object { $_.Name -like '.*' } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path (Join-Path $InstallDir 'node_modules')) { Remove-Item -Recurse -Force (Join-Path $InstallDir 'node_modules') -ErrorAction SilentlyContinue }

    $n = (Get-ChildItem -Path $InstallDir -File).Count
    Have "$n $(T 'launcher files' 'arquivos do launcher')"
    $vers = Join-Path $InstallDir 'game\versions'
    if (Test-Path $vers) {
        $names = (Get-ChildItem -Path $vers -Directory | ForEach-Object { $_.Name }) -join ' '
        Have (T 'Game versions:' 'Versoes do jogo:') $names
    }
    $rt = Join-Path $InstallDir 'game\runtime'
    if (Test-Path $rt) { Have (T 'Bundled Java runtime' 'Runtime Java incluido') }

    # ---- preserve game saves across an upgrade ----
    if (-not $NoPreserveSaves -and (Test-Path (Join-Path $PrevDir 'game\versions'))) {
        $carried = 0
        foreach ($vdir in (Get-ChildItem -Path (Join-Path $PrevDir 'game\versions') -Directory -ErrorAction SilentlyContinue)) {
            $oldSaves = Join-Path $vdir.FullName 'saves'
            if (-not (Test-Path $oldSaves)) { continue }
            if (-not (Get-ChildItem -Path $oldSaves -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { continue }
            $newSaves = Join-Path $InstallDir ("game\versions\" + $vdir.Name + "\saves")
            New-Item -ItemType Directory -Path $newSaves -Force | Out-Null
            Get-ChildItem -Path $newSaves -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $oldSaves '*') -Destination $newSaves -Recurse -Force -ErrorAction SilentlyContinue
            $carried++
            Skip (T 'carried over saves for' 'salvamentos preservados para') $vdir.Name
        }
        if ($carried -gt 0) { Have "$carried $(T 'version(s) with saves kept' 'versao(oes) com salvamentos mantidos')" }
    }
}

# =============================================================== electron ===
Section (T 'ELECTRON RUNTIME' 'RUNTIME ELECTRON')

if ($NoElectron) {
    Skip (T 'skipped (-NoElectron)' 'ignorado (-NoElectron)')
} else {
    $nm   = Join-Path $InstallDir 'node_modules'
    $dist = Join-Path $nm 'electron\dist'
    $exe  = Join-Path $dist 'electron.exe'
    $asset = if ($Arch -eq 'arm64') { "electron-v$ElectronVersion-win32-arm64.zip" } else { "electron-v$ElectronVersion-win32-x64.zip" }

    if (Test-Path $exe) {
        Have (T 'electron already installed' 'electron ja instalado') $exe
    } elseif ($DryRun) {
        Skip "[dry-run] would install electron $ElectronVersion ($asset)"
    } else {
        $zip = Join-Path $TmpDir 'electron.zip'
        Step (T 'Downloading Electron' 'Baixando Electron') "$ElectronVersion ($Arch)"
        if (-not (Get-File "https://github.com/electron/electron/releases/download/v$ElectronVersion/$asset" $zip)) {
            Die (T 'Could not download Electron.' 'Nao foi possivel baixar o Electron.')
        }
        Have (T 'Downloaded' 'Baixado') (HumanSize (Get-Item $zip).Length)

        if (Test-Path $dist) { Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $dist -Force | Out-Null
        try {
            Expand-Archive -Path $zip -DestinationPath $dist -Force -ErrorAction Stop
        } catch {
            Die (T 'Extraction failed.' 'Falha ao extrair.')
        }
        if (-not (Test-Path $exe)) { Die (T 'electron.exe missing after extraction.' 'electron.exe ausente apos extrair.') }

        New-Item -ItemType Directory -Path (Join-Path $nm 'electron') -Force | Out-Null
        $pkgJson = @"
{
  "name": "electron",
  "version": "$ElectronVersion",
  "main": "index.js",
  "private": true
}
"@
        Set-Content -Path (Join-Path $nm 'electron\package.json') -Value $pkgJson -Encoding UTF8
        Set-Content -Path (Join-Path $nm 'electron\index.js') -Value 'module.exports = require("path").join(__dirname, "dist", "electron.exe");' -Encoding UTF8

        # node_modules\.bin\electron.cmd -- what zelth.cmd calls
        $binDir = Join-Path $nm '.bin'
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        $shim = @"
@echo off
rem Zelth - Electron shim (generated by install.ps1)
"%~dp0..\electron\dist\electron.exe" %*
"@
        Set-Content -Path (Join-Path $binDir 'electron.cmd') -Value $shim -Encoding ASCII
        Ok (T 'electron installed (prebuilt, no npm)' 'electron instalado (pre-compilado, sem npm)') "$ElectronVersion"
    }
}

# ============================================================== shortcuts ===
Section (T 'SHORTCUTS' 'ATALHOS')

$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

if ($NoDesktopShortcut) {
    Skip (T 'skipped (-NoDesktopShortcut)' 'ignorado (-NoDesktopShortcut)')
} elseif ($DryRun) {
    Skip "[dry-run] would create shortcuts in $desktop"
} else {
    $cmdExe = Join-Path $InstallDir 'zelth.cmd'
    $icon = Join-Path $InstallDir 'zelth.png'

    $shell = New-Object -ComObject WScript.Shell
    foreach ($pair in @(@($desktop, "$AppName.lnk"), @($startMenu, "$AppName.lnk"))) {
        $dir = $pair[0]; $name = $pair[1]
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $sc = $shell.CreateShortcut((Join-Path $dir $name))
            $sc.TargetPath       = $cmdExe
            $sc.WorkingDirectory = $InstallDir
            $sc.Description      = "Zelth Launcher"
            $sc.WindowStyle      = 7   # minimised: a .cmd window should not stay up
            if (Test-Path $icon) { $sc.IconLocation = "$icon,0" }
            $sc.Save()
            Have (T 'shortcut' 'atalho') (Join-Path $dir $name)
        } catch {
            Warn (T 'could not create shortcut in' 'nao foi possivel criar atalho em') $dir
        }
    }
}

# ============================================================== uninstall ===
if (-not $DryRun) {
    $uninstaller = @'
$ErrorActionPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "Removing Zelth from $dir ..."
$targets = @(
    $dir,
    "$dir.prev",
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Zelth.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Zelth.lnk'),
    (Join-Path $env:LOCALAPPDATA 'zelth-cache')
)
foreach ($t in $targets) { if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force } }
Write-Host "Done. Game saves were removed too - back them up first if you care."
'@
    $unPath = Join-Path $InstallDir 'uninstall.ps1'
    Set-Content -Path $unPath -Value $uninstaller -Encoding UTF8
    Ok (T 'Uninstaller written' 'Desinstalador escrito') $unPath
}

# ================================================================= verify ===
Section (T 'VERIFY' 'VERIFICAR')

if ($DryRun) {
    Skip (T '[dry-run] skipped' '[dry-run] pulado')
} else {
    $all = @(
        'package.json', 'main.js', 'index.html', 'launcher.js',
        'zelth', 'zelth.cmd', 'uninstall.ps1', 'zelth-meteor-config.nbt'
    )
    $missing = @()
    foreach ($f in $all) { if (-not (Test-Path (Join-Path $InstallDir $f))) { $missing += $f } }
    if ($missing.Count -gt 0) { Die (T ('Missing launcher files: ' + ($missing -join ', ')) ('Arquivos do launcher ausentes: ' + ($missing -join ', '))) }
    Have (T 'all launcher files present' 'todos os arquivos presentes') ($all.Count)

    $exe = Join-Path $InstallDir 'node_modules\electron\dist\electron.exe'
    if (Test-Path $exe) { Have 'electron.exe present' } else { Warn (T 'electron.exe missing' 'electron.exe ausente') }

    $java = Join-Path $InstallDir 'game\runtime\java-runtime-delta\windows\java-runtime-delta\bin\java.exe'
    if (Test-Path $java) {
        try { $jv = (& $java -version 2>&1 | Select-Object -First 1); Have ('java ' + $jv) } catch { Have 'java runtime present' }
    } else {
        Warn (T 'bundled Java runtime not found' 'runtime Java nao encontrado')
    }

    $vers = Join-Path $InstallDir 'game\versions'
    if (Test-Path $vers) { Have ((Get-ChildItem $vers -Directory).Count.ToString() + ' ' + (T 'game versions' 'versoes do jogo')) }
}

# ================================================================ summary ===
Write-Host ''
Write-Host (Paint ([char]27 + '[1;32m') '  Zelth is ready.') -ForegroundColor Green
Write-Host ("  v$script:ZelthVersion")
Write-Host ''
Write-Host '  Play'
Write-Host ("    " + (Paint ([char]27 + '[36m') (Join-Path $InstallDir 'zelth.cmd')))
Write-Host ''
Write-Host '  Remove it later with'
Write-Host (Join-Path $InstallDir 'uninstall.ps1')
Write-Host ''
Write-Host (Paint ([char]27 + '[90m') '  (moon) moonlight, load fast.') -ForegroundColor DarkGray

# ================================================================= launch ===
if ($NoLaunch) {
    Skip (T 'not starting the launcher (-NoLaunch)' 'nao iniciando o launcher (-NoLaunch)')
} elseif ($DryRun) {
    Skip '[dry-run] would launch the app'
} else {
    $cmdExe = Join-Path $InstallDir 'zelth.cmd'
    if (Test-Path $cmdExe) {
        Start-Process -FilePath $cmdExe -WorkingDirectory $InstallDir
        Have (T 'launching Zelth ...' 'iniciando Zelth ...')
    } else {
        Warn (T 'zelth.cmd not found - start it from the Desktop shortcut' 'zelth.cmd nao encontrado - use o atalho da Area de Trabalho')
    }
}

Cleanup
