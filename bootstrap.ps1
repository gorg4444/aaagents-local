<#
  AAAgents - one-command local install. Pulls the full engine + trained models +
  desktop GUI from the PUBLIC GitHub Release and launches the desktop app, which
  spawns the no-Docker engine. Zero Docker, no GitHub login.

  Run on the target PC (PowerShell):

      irm https://raw.githubusercontent.com/gorg4444/aaagents-local/main/bootstrap.ps1 | iex

  Prereqs: an internet connection for the ~7 GB download. Python is BUNDLED.
  Optional: Ollama (`ollama pull llama3.2`) for AI analysis, and your Alpaca PAPER
  keys (entered in-app) to trade. The dashboard opens in demo mode without either.

  Apache-2.0. Copyright 2026 Georg Apeldorn (AAAgents).
#>
param(
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "AAAgents"),
  [string]$Repo       = "gorg4444/aaagents-local",
  [string]$Tag        = "v1",
  [int]$Port          = 8001,
  [switch]$NoLaunch
)
$ErrorActionPreference = "Stop"
function Info($m){ Write-Host "[info] $m" -ForegroundColor DarkGray }
function Ok($m){ Write-Host "[ ok ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[warn] $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

Write-Host "AAAgents - desktop install (engine + models + GUI, zero Docker)" -ForegroundColor Green

# 1. Prerequisites ----------------------------------------------------------
# Public release: NO GitHub login needed; assets download anonymously via curl
# (in-box on Windows 10/11). Python is bundled in the release.
$curl = Join-Path $env:WINDIR "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }
if (-not (Get-Command $curl -ErrorAction SilentlyContinue)) { Die "curl is required (in-box on Windows 10/11)." }

try {
  $tags = (Invoke-RestMethod -TimeoutSec 4 "http://127.0.0.1:11434/api/tags").models.name -join ", "
  if ($tags -match "llama3.2") { Ok "Ollama running (llama3.2 present)" }
  else { Warn "Ollama running but llama3.2 not found - run: ollama pull llama3.2" }
} catch { Warn "Ollama not reachable (optional) - install https://ollama.com then: ollama pull llama3.2" }

# 2. Download the release assets (anonymous; public repo) -------------------
$dl = Join-Path $InstallDir "dl"
New-Item -ItemType Directory -Force -Path $dl | Out-Null
Info "Fetching release $Tag asset list ..."
try { $rel = Invoke-RestMethod -TimeoutSec 30 "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
catch { Die "Could not read release '$Tag' from $Repo (is the repo public and the release published?)." }
if (-not $rel.assets) { Die "Release '$Tag' has no assets." }
Info "Downloading $($rel.assets.Count) assets (~7 GB; resumable - safe to re-run) ..."
$dlFull = [System.IO.Path]::GetFullPath($dl)
foreach ($a in $rel.assets) {
  # Harden against a crafted asset name (path traversal): force a bare filename
  # and confirm the resolved path stays inside the download dir before writing.
  $safe = [System.IO.Path]::GetFileName($a.name)
  if ([string]::IsNullOrWhiteSpace($safe) -or $safe -match '[\\/]') { Die "Invalid asset name: $($a.name)" }
  $out = Join-Path $dl $safe
  if (-not ([System.IO.Path]::GetFullPath($out)).StartsWith($dlFull + [System.IO.Path]::DirectorySeparatorChar)) {
    Die "Asset path escapes the download directory: $($a.name)"
  }
  Info ("  {0} ({1} MB)" -f $safe, [int]($a.size / 1MB))
  & $curl -L --fail --retry 5 --retry-delay 3 -C - -o "$out" $a.browser_download_url
  if ($LASTEXITCODE -ne 0) { Die "Download failed for $safe - re-run to resume." }
}
Ok "assets downloaded to $dl"

# 3. Verify + reassemble split parts ---------------------------------------
$manifest = Join-Path $dl "SHA256SUMS.txt"
if (Test-Path $manifest) {
  Info "Verifying checksums ..."
  foreach ($line in Get-Content $manifest) {
    if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
      $want = $matches[1].ToLower(); $name = $matches[2]
      $f = Join-Path $dl $name
      if (Test-Path $f) {
        $got = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $want) { Die "Checksum mismatch for $name - re-download." }
      }
    }
  }
  Ok "checksums verified"
}

$app = Join-Path $InstallDir "app"
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
New-Item -ItemType Directory -Force -Path $app | Out-Null

# Join any split engine parts (part-00, part-01, ...) back into one zip, in order.
$parts = Get-ChildItem $dl -Filter "aaagents-engine.tar.part-*" | Sort-Object Name
$engineZip = Join-Path $dl "aaagents-engine.tar"
if ($parts) {
  Remove-Item $engineZip -ErrorAction SilentlyContinue
  Info "Reassembling $($parts.Count) engine parts ..."
  cmd /c "copy /b `"$(( $parts | ForEach-Object { $_.FullName }) -join '`"+`"')`" `"$engineZip`"" | Out-Null
}
if (-not (Test-Path $engineZip)) { Die "Engine archive missing after reassembly." }

# Verify the reassembled archive against the full-zip hash in the manifest.
if (Test-Path $manifest) {
  $full = Get-Content $manifest | Where-Object { $_ -match 'aaagents-engine\.tar\s*$' } | Select-Object -First 1
  if ($full -and $full -match '^\s*([0-9a-fA-F]{64})') {
    $want = $matches[1].ToLower()
    Info "Verifying reassembled engine archive ..."
    if ((Get-FileHash $engineZip -Algorithm SHA256).Hash.ToLower() -ne $want) {
      Die "Reassembled engine.tar checksum mismatch - re-run to re-download."
    }
    Ok "engine archive verified"
  }
}

# Extract with the in-box bsdtar (ZIP64-safe, streams). Windows PowerShell 5.1's
# Expand-Archive (Microsoft.PowerShell.Archive v1.0.1.0) corrupts/OOMs on a >4 GB
# ZIP64 archive like this one, so it is NOT used here.
$tar = Join-Path $env:WINDIR "System32\tar.exe"
if (-not (Test-Path $tar)) { $tar = "tar" }
Info "Extracting engine + models (~6 GB - takes a minute) ..."
& $tar -xf "$engineZip" -C "$app"
if ($LASTEXITCODE -ne 0) { Die "Extraction failed (need Windows 10/11 in-box tar.exe at System32)." }
$guiZip = Join-Path $dl "aaagents-gui.tar"
if (Test-Path $guiZip) {
  $guiDir = Join-Path $app "gui"
  New-Item -ItemType Directory -Force -Path $guiDir | Out-Null
  & $tar -xf "$guiZip" -C "$guiDir"
}
Ok "extracted to $app"

# 4. Python venv + dependencies --------------------------------------------
$botDir = Join-Path $app "AI Trading Bot"
if (-not (Test-Path (Join-Path $botDir "requirements.oss.txt"))) {
  Die "Bundle layout unexpected: $botDir\requirements.oss.txt not found."
}
$engineReady = $false
$vpy = $null

# 4a. Preferred: the BUNDLED relocatable Python (interpreter + all deps) — no
#     system Python required, no pip wait.
$pyParts = Get-ChildItem $dl -Filter "aaagents-python.tar.part-*" -ErrorAction SilentlyContinue | Sort-Object Name
$pyTar = Join-Path $dl "aaagents-python.tar"
if ($pyParts) {
  Remove-Item $pyTar -ErrorAction SilentlyContinue
  cmd /c "copy /b `"$(( $pyParts | ForEach-Object { $_.FullName }) -join '`"+`"')`" `"$pyTar`"" | Out-Null
}
if (Test-Path $pyTar) {
  Info "Extracting bundled Python (no system Python required) ..."
  $pyRoot = Join-Path $InstallDir "python"
  if (Test-Path $pyRoot) { Remove-Item -Recurse -Force $pyRoot }
  & $tar -xf "$pyTar" -C $InstallDir
  $cand = Join-Path $InstallDir "python\python.exe"
  if (Test-Path $cand) { $vpy = $cand; $engineReady = $true; Ok "bundled Python ready (deps included)" }
}

# 4b. Fallback: system Python + venv (only if no bundled Python shipped).
if (-not $vpy) {
  $venv = Join-Path $InstallDir "venv"
  $svpy = Join-Path $venv "Scripts\python.exe"
  if (Get-Command python -ErrorAction SilentlyContinue) {
    if (-not (Test-Path $svpy)) { Info "Creating venv ..."; & python -m venv $venv }
    if (Test-Path $svpy) {
      Info "Installing dependencies (requirements.oss.txt) - a few minutes ..."
      & $svpy -m pip install --upgrade pip | Out-Null
      & $svpy -m pip install -r (Join-Path $botDir "requirements.oss.txt")
      if ($LASTEXITCODE -eq 0) { Ok "dependencies installed"; $vpy = $svpy; $engineReady = $true }
      else { Warn "Dependency install hit errors - the app still opens; the engine starts once resolved." }
    }
  } else {
    Warn "No bundled Python and Python 3.12+ not found - the app opens; install Python for the engine."
  }
}

# 5. Launch the desktop GUI (it spawns the no-Docker engine) ----------------
# The GUI opens regardless of engine readiness; it shows engine status in-app and
# adopts the engine once it is running.
$exe = Get-ChildItem (Join-Path $app "gui") -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -notmatch "unins|crash|setup" } | Select-Object -First 1
if ($vpy -and (Test-Path $vpy)) { $env:AAA_PYTHON = $vpy }  # GUI spawns the engine with THIS interpreter
$env:AAA_SOURCE_ROOT = $app                      # ... from <app>\AI Trading Bot (native-engine-manager.cjs)
$env:AAA_ENGINE_PORT = "$Port"
$env:AAA_DEMO_BOOT   = "true"                     # dashboard boots before keys are set (paper, never trades)
Ok "Setup complete."
Write-Host ""
Write-Host "  Installed to: $InstallDir" -ForegroundColor Green
if ($engineReady) {
  Write-Host "  Opens in DEMO mode (dashboard, no trading); add your Alpaca PAPER keys in-app to go live." -ForegroundColor Green
} else {
  Write-Host "  The app will open; install Python 3.12+ then re-run to enable the engine." -ForegroundColor Yellow
}
if ($NoLaunch) { Info "Skipping launch (--NoLaunch). Start later: `"$($exe.FullName)`""; exit 0 }
if (-not $exe) { Warn "GUI exe not found under $app\gui."; exit 0 }
Info "Launching the desktop app ..."
Start-Process -FilePath $exe.FullName
Ok "AAAgents is starting in DEMO mode - the dashboard opens without keys; add Alpaca PAPER keys in-app to trade."
