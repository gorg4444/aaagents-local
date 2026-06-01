<#
  AAAgents - one-command local install (private). Pulls the full engine + models +
  desktop GUI from the private GitHub Release and launches the desktop app, which
  spawns the no-Docker engine. Zero Docker.

  Run on the target PC (gh must be installed + `gh auth login` done once):

      & ([scriptblock]::Create((gh api -H "Accept: application/vnd.github.raw" `
          /repos/gorg4444/aaagents-local/contents/bootstrap.ps1)))

  Or clone + run:  gh repo clone gorg4444/aaagents-local; .\aaagents-local\bootstrap.ps1

  Prereqs on the target PC: Python 3.12+, Ollama (`ollama pull llama3.2`), gh (authed),
  and your Alpaca PAPER API keys (entered in-app on first run).
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
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Die "GitHub CLI (gh) is required. Install from https://cli.github.com then run 'gh auth login'."
}
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Die "gh is not authenticated. Run 'gh auth login' (your account that can read $Repo)." }
Ok "gh authenticated"

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Die "Python 3.12+ is required on PATH (https://python.org)." }
$pyver = (& python -c "import sys;print('%d.%d'%sys.version_info[:2])")
Ok "python $pyver"

try {
  $tags = (Invoke-RestMethod -TimeoutSec 4 "http://127.0.0.1:11434/api/tags").models.name -join ", "
  if ($tags -match "llama3.2") { Ok "Ollama running (llama3.2 present)" }
  else { Warn "Ollama running but llama3.2 not found - run: ollama pull llama3.2" }
} catch { Warn "Ollama not reachable - install from https://ollama.com, then: ollama serve; ollama pull llama3.2" }

# 2. Download the release assets -------------------------------------------
$dl = Join-Path $InstallDir "dl"
New-Item -ItemType Directory -Force -Path $dl | Out-Null
Info "Downloading release $Tag from $Repo (this is large - ~6 GB; do not interrupt) ..."
& gh release download $Tag -R $Repo -D $dl --clobber
if ($LASTEXITCODE -ne 0) { Die "Release download failed. Confirm the release '$Tag' exists and you can read $Repo." }
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
$venv = Join-Path $InstallDir "venv"
$vpy  = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path $vpy)) { Info "Creating venv ..."; & python -m venv $venv }
Info "Installing dependencies (requirements.oss.txt) - a few minutes ..."
& $vpy -m pip install --upgrade pip | Out-Null
& $vpy -m pip install -r (Join-Path $botDir "requirements.oss.txt")
if ($LASTEXITCODE -ne 0) { Die "Dependency install failed (see output above)." }
Ok "dependencies installed"

# 5. Launch the desktop GUI (it spawns the no-Docker engine) ----------------
$exe = Get-ChildItem (Join-Path $app "gui") -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -notmatch "unins|crash|setup" } | Select-Object -First 1
$env:AAA_PYTHON      = $vpy        # GUI spawns the engine with THIS interpreter (resolve-python.cjs)
$env:AAA_SOURCE_ROOT = $app        # ... from <app>\AI Trading Bot (native-engine-manager.cjs)
$env:AAA_ENGINE_PORT = "$Port"
Ok "Setup complete."
Write-Host ""
Write-Host "  Engine + models + GUI installed to: $InstallDir" -ForegroundColor Green
Write-Host "  On first run, enter your Alpaca PAPER keys in the app's onboarding." -ForegroundColor Green
if ($NoLaunch) { Info "Skipping launch (--NoLaunch). Start later: `"$($exe.FullName)`""; exit 0 }
if (-not $exe) { Warn "GUI exe not found under $app\gui - start the engine headless: & '$vpy' -u -m core.engine (cwd $botDir)"; exit 0 }
Info "Launching the desktop app ..."
Start-Process -FilePath $exe.FullName
Ok "AAAgents is starting. The app will bring up the engine on :$Port."
