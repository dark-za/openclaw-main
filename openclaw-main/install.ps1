# =============================================================================
# OpenClaw — Smart Installation Script (Windows PowerShell)
# =============================================================================
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   install.ps1 -SkipModel -SkipPlaywright
#
# Requires: PowerShell 5.1+ (built into all Windows 10/11 versions)
# =============================================================================
[CmdletBinding()]
param(
    [switch]$SkipModel,
    [switch]$SkipLlama,
    [switch]$SkipPlaywright,
    [switch]$DryRun,
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"   # Don't stop on non-critical errors
Set-StrictMode -Version Latest

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Write-Step  { param($M) Write-Host "`n[openclaw] " -NoNewline -ForegroundColor Cyan; Write-Host $M -ForegroundColor White }
function Write-Ok    { param($M) Write-Host "  [OK]  $M" -ForegroundColor Green }
function Write-Warn  { param($M) Write-Host "  [WARN] $M" -ForegroundColor Yellow }
function Write-Info  { param($M) Write-Host "  [>>]  $M" -ForegroundColor Cyan }
function Write-Fatal { param($M) Write-Host "`n[ERROR] $M" -ForegroundColor Red; exit 1 }

function Sep { Write-Host ("─" * 56) -ForegroundColor DarkGray }

Sep
Write-Host "  OpenClaw — Smart Installation Bootstrap (Windows)" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Sep

# ── CI detection ───────────────────────────────────────────────────────────────
$IsCI = ($env:CI -eq "true") -or ($env:GITHUB_ACTIONS -eq "true")
if ($IsCI) {
    Write-Warn "CI environment — disabling heavy steps"
    $SkipModel = $true
    $SkipPlaywright = $true
}

# ── Locate project root ────────────────────────────────────────────────────────
Write-Step "📂 Locating project root"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = $null

foreach ($candidate in @($ScriptDir, (Split-Path -Parent $ScriptDir))) {
    if (Test-Path (Join-Path $candidate "package.json")) {
        $ProjectRoot = $candidate
        break
    }
}

if (-not $ProjectRoot) {
    # Search one level down
    foreach ($dir in Get-ChildItem -Path $ScriptDir -Directory) {
        if (Test-Path (Join-Path $dir.FullName "package.json")) {
            $ProjectRoot = $dir.FullName
            break
        }
    }
}

if (-not $ProjectRoot) {
    Write-Fatal "Cannot find package.json. Navigate into the project folder and run: powershell -File install.ps1"
}

Write-Ok "Project root: $ProjectRoot"
Set-Location $ProjectRoot

# ── System information ─────────────────────────────────────────────────────────
Write-Step "🖥  Detecting system"
$OS = [System.Environment]::OSVersion.VersionString
$Arch = $env:PROCESSOR_ARCHITECTURE
Write-Ok "OS: $OS"
Write-Ok "Arch: $Arch"

$TotalRAM = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Ok "RAM: ~${TotalRAM} GB"

$CPU = (Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).Name
Write-Ok "CPU: $CPU"

# ── GPU detection ──────────────────────────────────────────────────────────────
Write-Step "🔍 Detecting hardware accelerator"
$GpuKind = "none"
$CmakeArgs = ""
$GpuName = "CPU-only"

# NVIDIA
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    try {
        $nvidiaOut = & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>$null | Select-Object -First 1
        if ($nvidiaOut) {
            $GpuKind = "cuda"
            $GpuName = $nvidiaOut.Trim()
            $CmakeArgs = "-DGGML_CUDA=on"
            Write-Ok "NVIDIA GPU: $GpuName"
            $CudaVer = & nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>$null | Select-Object -First 1
            Write-Ok "CUDA: $CudaVer"
        }
    } catch { }
}

if ($GpuKind -eq "none") {
    # Try WMI for GPU info
    $Gpus = Get-CimInstance -Class Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft Basic" }
    if ($Gpus) {
        $Gpu = $Gpus | Select-Object -First 1
        Write-Info "Display adapter: $($Gpu.Name)"
        if ($Gpu.Name -match "NVIDIA") {
            $GpuKind = "cuda"
            $GpuName = $Gpu.Name
            $CmakeArgs = "-DGGML_CUDA=on"
            Write-Ok "NVIDIA GPU via WMI: $GpuName"
            Write-Warn "nvidia-smi not in PATH — ensure CUDA toolkit is installed"
        } elseif ($Gpu.Name -match "AMD|Radeon") {
            Write-Info "AMD GPU detected — ROCm on Windows is experimental"
            Write-Info "For best results, install WSL2 with ROCm drivers"
        }
    }
}

if ($GpuKind -eq "none") {
    Write-Warn "No accelerator detected — CPU-only inference"
}

# ── Prerequisite checks ────────────────────────────────────────────────────────
Write-Step "🔧 Checking prerequisites"

# Node.js
$NodeOk = $false
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $NodeVer = (node --version).TrimStart("v")
    $NodeMajor = [int]($NodeVer.Split(".")[0])
    $NodeMinor = [int]($NodeVer.Split(".")[1])
    if ($NodeMajor -gt 22 -or ($NodeMajor -eq 22 -and $NodeMinor -ge 16)) {
        Write-Ok "Node.js v$NodeVer"
        $NodeOk = $true
    } else {
        Write-Warn "Node.js v$NodeVer — need ≥v22.16.0"
    }
}

if (-not $NodeOk) {
    Write-Warn "Node.js ≥22 required. Please install from: https://nodejs.org"
    Write-Info "Trying winget…"
    try {
        winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
        Write-Ok "Node.js installed via winget — restart your terminal and re-run this script"
        exit 0
    } catch {
        Write-Fatal "Node.js not found. Download from https://nodejs.org (LTS v22+)"
    }
}

# Package manager
$PkgMgr = "npm"
if (Get-Command pnpm -ErrorAction SilentlyContinue) {
    $PkgMgr = "pnpm"
    Write-Ok "Package manager: pnpm $(pnpm --version)"
} else {
    Write-Info "Installing pnpm…"
    try {
        npm install -g pnpm
        if (Get-Command pnpm -ErrorAction SilentlyContinue) {
            $PkgMgr = "pnpm"
            Write-Ok "pnpm installed"
        }
    } catch {
        Write-Warn "pnpm install failed — using npm"
    }
}

# Python
$PythonExe = $null
$PythonVer = ""
foreach ($candidate in @("python", "python3", "py")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $ver = & $candidate -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}.{v.micro}')" 2>$null
            if ($ver -match "^(\d+)\.(\d+)\.(\d+)$") {
                $maj = [int]$Matches[1]; $min = [int]$Matches[2]
                if ($maj -gt 3 -or ($maj -eq 3 -and $min -ge 10)) {
                    $PythonExe = $candidate
                    $PythonVer = $ver
                    Write-Ok "Python $ver ($candidate)"
                    break
                } else {
                    Write-Warn "Python $ver ($candidate) — need ≥3.10"
                }
            }
        } catch { }
    }
}

if (-not $PythonExe) {
    Write-Warn "Python 3.10+ not found"
    Write-Info "Trying winget…"
    try {
        winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
        $PythonExe = "python"
        Write-Ok "Python installed — restart your terminal and re-run"
        exit 0
    } catch {
        Write-Warn "Auto-install failed. Install from https://python.org/downloads"
        Write-Warn "Local inference will be disabled"
    }
}

# Visual Studio Build Tools (C++ compiler)
$HasMSVC = $false
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vsWhere) {
    $vsInstall = & $vsWhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsInstall) {
        Write-Ok "MSVC found: $vsInstall"
        $HasMSVC = $true
    }
}
if (-not $HasMSVC) {
    Write-Warn "MSVC C++ compiler not found"
    Write-Warn "Install Visual Studio Build Tools: https://visualstudio.microsoft.com/visual-cpp-build-tools/"
    Write-Warn "Select 'Desktop development with C++' workload"
    Write-Info "llama-cpp-python may use a prebuilt wheel if available"
}

# ── Dry-run exit ───────────────────────────────────────────────────────────────
if ($DryRun) {
    Sep
    Write-Warn "Dry-run mode — no installs performed"
    Sep
    exit 0
}

# ── Node.js install ────────────────────────────────────────────────────────────
Write-Step "📦 Installing Node.js dependencies"
$env:OPENCLAW_SKIP_SETUP = "1"
& $PkgMgr install
if ($LASTEXITCODE -ne 0) {
    Write-Fatal "$PkgMgr install failed. Check the output above."
}
Write-Ok "Node.js dependencies installed"

# ── Python / local inference setup ────────────────────────────────────────────
if ($PythonExe -and -not $env:OPENCLAW_SKIP_SETUP) {
    $setupArgs = @()
    if ($SkipModel)      { $setupArgs += "--skip-model" }
    if ($SkipLlama)      { $setupArgs += "--skip-llama" }
    if ($SkipPlaywright) { $setupArgs += "--skip-playwright" }

    if (Test-Path "bin\setup.py") {
        Write-Step "🦙 Running local inference setup"
        & $PythonExe bin\setup.py @setupArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Setup completed with warnings — check output above"
        }
    } else {
        Write-Step "🦙 Installing Python dependencies (fallback)"
        & $PythonExe -m pip install --upgrade huggingface-hub

        if (-not $SkipLlama) {
            if ($CmakeArgs) {
                $env:CMAKE_ARGS = $CmakeArgs
                Write-Info "CMAKE_ARGS=$CmakeArgs"
            }
            & $PythonExe -m pip install "llama-cpp-python[server]>=0.3.4"
            if ($LASTEXITCODE -ne 0 -and $CmakeArgs) {
                Write-Warn "GPU build failed — retrying CPU build"
                Remove-Item Env:\CMAKE_ARGS -ErrorAction SilentlyContinue
                & $PythonExe -m pip install "llama-cpp-python[server]>=0.3.4"
            }
        }

        if (-not $SkipPlaywright) {
            npx playwright install --with-deps
        }
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Sep
Write-Host "  OpenClaw installation complete!" -ForegroundColor Green
Sep
Write-Host "  Platform : Windows ($Arch)"
Write-Host "  GPU      : $GpuName"
Write-Host "  Node.js  : $(node --version)"
Write-Host "  Python   : $PythonVer"
Write-Host ""
Write-Host "  Start inference server:" -ForegroundColor Cyan
Write-Host "    python scripts/llama_cpp_server.py"
Write-Host ""
Write-Host "  Then start OpenClaw:" -ForegroundColor Cyan
Write-Host "    npm start"
Sep
