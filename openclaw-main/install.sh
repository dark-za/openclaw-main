#!/usr/bin/env bash
# =============================================================================
# OpenClaw — Smart Installation Script (Linux / macOS)
# =============================================================================
# Usage:
#   bash install.sh            # full install (recommended)
#   bash install.sh --skip-model       # skip GGUF model download
#   bash install.sh --skip-llama       # skip llama-cpp-python
#   bash install.sh --skip-playwright  # skip Playwright browser deps
#   bash install.sh --dry-run          # detect only, no installs
#
# Environment overrides:
#   OPENCLAW_SKIP_SETUP=1          skip Python local-inference setup
#   OPENCLAW_SETUP_SKIP_MODEL=1    skip model download
#   OPENCLAW_SETUP_SKIP_LLAMA=1    skip llama-cpp-python
#   OPENCLAW_SETUP_SKIP_PLAYWRIGHT=1  skip Playwright
#   HF_TOKEN                       HuggingFace token (private models)
# =============================================================================
set -euo pipefail

# ── Colour & output ────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null && tput colors &>/dev/null && [ "$(tput colors)" -ge 8 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

PREFIX="${BOLD}${CYAN}[openclaw]${RESET}"
step()  { echo -e "\n${PREFIX} ${BOLD}$*${RESET}"; }
ok()    { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
die()   { echo -e "\n${RED}✗ Error:${RESET} $*" >&2; exit 1; }
info()  { echo -e "  ${CYAN}→${RESET}  $*"; }
sep()   { echo -e "${BOLD}──────────────────────────────────────────────────${RESET}"; }

# ── CLI flags ──────────────────────────────────────────────────────────────────
SKIP_MODEL="${OPENCLAW_SETUP_SKIP_MODEL:-0}"
SKIP_LLAMA="${OPENCLAW_SETUP_SKIP_LLAMA:-0}"
SKIP_PLAYWRIGHT="${OPENCLAW_SETUP_SKIP_PLAYWRIGHT:-0}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --skip-model)       SKIP_MODEL=1 ;;
    --skip-llama)       SKIP_LLAMA=1 ;;
    --skip-playwright)  SKIP_PLAYWRIGHT=1 ;;
    --dry-run|-n)       DRY_RUN=1 ;;
    --help|-h)
      sed -n '3,20p' "$0" | sed 's/^# //; s/^#//'
      exit 0 ;;
    *) warn "Unknown flag: $arg (ignoring)" ;;
  esac
done

sep
echo -e "  ${BOLD}${CYAN}OpenClaw${RESET} — Smart Installation Bootstrap"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
sep

# ── CI auto-detection ──────────────────────────────────────────────────────────
if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "${DOCKER_BUILD:-}" = "true" ]; then
  warn "CI environment detected — disabling heavy steps"
  [ "$SKIP_MODEL" = "0" ]      && SKIP_MODEL=1      && warn "  Auto-set: --skip-model"
  [ "$SKIP_PLAYWRIGHT" = "0" ] && SKIP_PLAYWRIGHT=1  && warn "  Auto-set: --skip-playwright"
fi

# ── Locate the project root ─────────────────────────────────────────────────────
# Handles the common clone scenario where the repo is nested:
#   git clone → openclaw-main/           ← clone root
#                  openclaw-main/         ← actual project (has package.json)
#
find_project_root() {
  local start_dir
  start_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Option 1: package.json is right here (script lives inside the project)
  if [ -f "$start_dir/package.json" ]; then
    echo "$start_dir"
    return 0
  fi

  # Option 2: one level up
  if [ -f "$(dirname "$start_dir")/package.json" ]; then
    echo "$(dirname "$start_dir")"
    return 0
  fi

  # Option 3: one level down (nested clone — the common case)
  local name
  for subdir in "$start_dir"/*/; do
    if [ -f "$subdir/package.json" ]; then
      echo "${subdir%/}"
      return 0
    fi
  done

  # Option 4: check current working directory
  if [ -f "$PWD/package.json" ]; then
    echo "$PWD"
    return 0
  fi

  return 1
}

step "📂 Locating project root"
PROJECT_ROOT="$(find_project_root)" || die \
  "Could not find package.json anywhere near this script.\n\n" \
  "Try:\n  cd openclaw-main   # navigate into the nested folder first\n  bash install.sh"
ok "Project root: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# ── System detection ───────────────────────────────────────────────────────────
step "🖥  Detecting system"
OS="$(uname -s)"     # Linux | Darwin
ARCH="$(uname -m)"   # x86_64 | arm64 | aarch64
ok "OS: $OS  Arch: $ARCH"

# macOS version
if [ "$OS" = "Darwin" ]; then
  MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
  ok "macOS: $MACOS_VER"
fi

# Linux distro
if [ "$OS" = "Linux" ] && [ -f /etc/os-release ]; then
  DISTRO_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
  ok "Distro: $DISTRO_NAME"
fi

# Memory
if command -v free &>/dev/null; then
  MEM_GB=$(( $(free -m | awk '/^Mem:/{print $2}') / 1024 ))
  ok "RAM: ~${MEM_GB} GB"
elif [ "$OS" = "Darwin" ]; then
  MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  MEM_GB=$(( MEM_BYTES / 1073741824 ))
  ok "RAM: ~${MEM_GB} GB"
fi

# CPU cores
NCPU="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 1)"
ok "CPUs: $NCPU logical cores"

# ── GPU / Accelerator detection ─────────────────────────────────────────────────
step "🔍 Detecting hardware accelerator"
GPU_KIND="none"
GPU_NAME="CPU-only"
CMAKE_ARGS=""

# NVIDIA
if command -v nvidia-smi &>/dev/null; then
  NVIDIA_OUT="$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo "")"
  if [ -n "$NVIDIA_OUT" ]; then
    GPU_KIND="cuda"
    GPU_NAME="$NVIDIA_OUT"
    CMAKE_ARGS="-DGGML_CUDA=on"
    ok "NVIDIA GPU: $GPU_NAME"
    CUDA_VER="$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")"
    ok "CUDA version: $CUDA_VER"
  fi
fi

# Apple Silicon → always Metal
if [ "$GPU_KIND" = "none" ] && [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then
  GPU_KIND="metal"
  GPU_NAME="Apple Silicon (Metal)"
  CMAKE_ARGS="-DGGML_METAL=on"
  ok "Metal GPU (Apple Silicon)"
fi

# AMD ROCm
if [ "$GPU_KIND" = "none" ] && command -v rocm-smi &>/dev/null; then
  ROCM_OUT="$(rocm-smi --showproductname 2>/dev/null | grep -i 'card\|gpu' | head -1 || echo "")"
  if [ -n "$ROCM_OUT" ]; then
    GPU_KIND="rocm"
    GPU_NAME="$ROCM_OUT"
    CMAKE_ARGS="-DGGML_HIPBLAS=on"
    ok "AMD ROCm GPU: $GPU_NAME"
  fi
fi

if [ "$GPU_KIND" = "none" ]; then
  warn "No GPU detected — using CPU-only inference"
  warn "For GPU support, install CUDA/ROCm drivers then re-run install.sh"
fi

# ── Dependency checks ──────────────────────────────────────────────────────────
step "🔧 Checking prerequisite software"

# ── Node.js ──
MIN_NODE_MAJOR=22
MIN_NODE_MINOR=16
NODE_OK=0
NODE_VERSION=""

if command -v node &>/dev/null; then
  NODE_VERSION="$(node --version | tr -d 'v')"
  NODE_MAJOR="$(echo "$NODE_VERSION" | cut -d. -f1)"
  NODE_MINOR="$(echo "$NODE_VERSION" | cut -d. -f2)"
  if [ "$NODE_MAJOR" -gt "$MIN_NODE_MAJOR" ] || \
     { [ "$NODE_MAJOR" -eq "$MIN_NODE_MAJOR" ] && [ "$NODE_MINOR" -ge "$MIN_NODE_MINOR" ]; }; then
    ok "Node.js v$NODE_VERSION"
    NODE_OK=1
  else
    warn "Node.js v$NODE_VERSION found — need ≥v${MIN_NODE_MAJOR}.${MIN_NODE_MINOR}.0"
  fi
fi

if [ "$NODE_OK" = "0" ]; then
  step "📦 Installing Node.js via nvm"
  if [ -f "$HOME/.nvm/nvm.sh" ] || command -v nvm &>/dev/null; then
    # shellcheck disable=SC1090
    [ -f "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh"
    info "nvm found — installing Node.js $MIN_NODE_MAJOR"
    nvm install "$MIN_NODE_MAJOR" && nvm use "$MIN_NODE_MAJOR" && nvm alias default "$MIN_NODE_MAJOR"
    ok "Node.js $(node --version)"
  else
    info "Installing nvm + Node.js $MIN_NODE_MAJOR…"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    # shellcheck disable=SC1090
    source "$HOME/.nvm/nvm.sh"
    nvm install "$MIN_NODE_MAJOR"
    nvm alias default "$MIN_NODE_MAJOR"
    ok "Node.js $(node --version)"
  fi
fi

# ── Package manager: prefer pnpm, fall back to npm ──
PKG_MGR="npm"
if command -v pnpm &>/dev/null; then
  PKG_MGR="pnpm"
  ok "Package manager: pnpm $(pnpm --version)"
elif command -v npm &>/dev/null; then
  ok "Package manager: npm $(npm --version)"
  # Try to enable pnpm via corepack (Node 22+ ships with it)
  if command -v corepack &>/dev/null; then
    info "Enabling pnpm via corepack…"
    corepack enable pnpm &>/dev/null && \
    corepack prepare pnpm@latest --activate &>/dev/null && \
    PKG_MGR="pnpm" && ok "pnpm enabled via corepack" || true
  fi
  if [ "$PKG_MGR" = "npm" ]; then
    info "Installing pnpm globally…"
    npm install -g pnpm &>/dev/null && PKG_MGR="pnpm" && ok "pnpm installed" || \
    warn "pnpm install failed — falling back to npm (slower)"
  fi
fi

# ── Python ──
MIN_PY_MAJOR=3; MIN_PY_MINOR=10
PYTHON_EXE=""
PYTHON_VERSION=""

for candidate in python3 python python3.12 python3.11 python3.10; do
  if command -v "$candidate" &>/dev/null; then
    VER="$(${candidate} -c 'import sys; v=sys.version_info; print(f"{v.major}.{v.minor}.{v.micro}")' 2>/dev/null || echo "")"
    if [ -n "$VER" ]; then
      PY_MAJOR="$(echo "$VER" | cut -d. -f1)"
      PY_MINOR="$(echo "$VER" | cut -d. -f2)"
      if [ "$PY_MAJOR" -gt "$MIN_PY_MAJOR" ] || \
         { [ "$PY_MAJOR" -eq "$MIN_PY_MAJOR" ] && [ "$PY_MINOR" -ge "$MIN_PY_MINOR" ]; }; then
        PYTHON_EXE="$candidate"
        PYTHON_VERSION="$VER"
        ok "Python $VER ($candidate)"
        break
      else
        warn "Python $VER ($candidate) — need ≥$MIN_PY_MAJOR.$MIN_PY_MINOR"
      fi
    fi
  fi
done

if [ -z "$PYTHON_EXE" ]; then
  warn "Python $MIN_PY_MAJOR.$MIN_PY_MINOR+ not found"
  if [ "$OS" = "Linux" ]; then
    info "Attempting system Python install…"
    if command -v apt-get &>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y python3 python3-pip python3-venv
      PYTHON_EXE="python3"
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y python3 python3-pip
      PYTHON_EXE="python3"
    elif command -v pacman &>/dev/null; then
      sudo pacman -Sy --noconfirm python python-pip
      PYTHON_EXE="python3"
    else
      warn "Unknown package manager — cannot auto-install Python"
      warn "Install Python 3.10+: https://python.org/downloads"
    fi
  elif [ "$OS" = "Darwin" ]; then
    if command -v brew &>/dev/null; then
      info "Installing Python via Homebrew…"
      brew install python@3.12
      PYTHON_EXE="python3.12"
    else
      warn "Homebrew not found — install Python 3.10+ from https://python.org/downloads"
    fi
  fi
fi

# ── pip bootstrap (Ubuntu 24.04 ships Python without pip) ──────────────────────
if [ -n "$PYTHON_EXE" ]; then
  if ! "$PYTHON_EXE" -m pip --version &>/dev/null 2>&1; then
    warn "pip not found for $PYTHON_EXE — installing…"
    # Try 1: ensurepip (works on most CPython builds)
    if "$PYTHON_EXE" -m ensurepip --upgrade &>/dev/null 2>&1; then
      ok "pip installed via ensurepip"
    elif [ "$OS" = "Linux" ] && command -v apt-get &>/dev/null; then
      # Try 2: system package (Ubuntu/Debian)
      info "Installing python3-pip via apt-get…"
      sudo apt-get install -y python3-pip python3-venv
      ok "pip installed via apt-get"
    elif [ "$OS" = "Linux" ] && command -v dnf &>/dev/null; then
      sudo dnf install -y python3-pip && ok "pip installed via dnf"
    elif [ "$OS" = "Linux" ] && command -v pacman &>/dev/null; then
      sudo pacman -Sy --noconfirm python-pip && ok "pip installed via pacman"
    elif command -v curl &>/dev/null; then
      # Try 3: get-pip.py (universal fallback)
      info "Installing pip via get-pip.py…"
      curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$PYTHON_EXE"
      ok "pip installed via get-pip.py"
    else
      warn "Cannot install pip automatically"
      warn "Run: sudo apt-get install python3-pip   (or equivalent for your distro)"
      PYTHON_EXE=""   # disable Python steps — pip is required
    fi
    # Upgrade pip to latest after install
    [ -n "$PYTHON_EXE" ] && "$PYTHON_EXE" -m pip install --upgrade pip --quiet 2>/dev/null || true
  else
    ok "pip $(${PYTHON_EXE} -m pip --version | awk '{print $2}')"
  fi
fi

# ── C++ compiler (needed for llama-cpp-python build) ──
HAS_COMPILER=0
if command -v gcc &>/dev/null || command -v clang &>/dev/null || command -v cc &>/dev/null; then
  CC_NAME="$(command -v gcc || command -v clang || command -v cc)"
  CC_VER="$($CC_NAME --version 2>/dev/null | head -1 || echo 'unknown')"
  ok "C++ compiler: $CC_VER"
  HAS_COMPILER=1
else
  warn "No C++ compiler found (needed for llama-cpp-python)"
  if [ "$OS" = "Linux" ]; then
    info "Installing build-essential…"
    if command -v apt-get &>/dev/null; then
      sudo apt-get install -y build-essential cmake && HAS_COMPILER=1 && ok "build-essential installed"
    elif command -v dnf &>/dev/null; then
      sudo dnf groupinstall -y "Development Tools" && sudo dnf install -y cmake && HAS_COMPILER=1
    elif command -v pacman &>/dev/null; then
      sudo pacman -Sy --noconfirm base-devel cmake && HAS_COMPILER=1
    fi
  elif [ "$OS" = "Darwin" ]; then
    info "Installing Xcode Command Line Tools…"
    xcode-select --install 2>/dev/null || true
    warn "Re-run install.sh after Xcode CLT installation completes"
  fi
fi

# cmake check
if ! command -v cmake &>/dev/null; then
  warn "cmake not found"
  if [ "$OS" = "Linux" ] && command -v apt-get &>/dev/null; then
    sudo apt-get install -y cmake && ok "cmake installed"
  elif [ "$OS" = "Darwin" ] && command -v brew &>/dev/null; then
    brew install cmake && ok "cmake installed"
  fi
fi

# ── git check ──
if ! command -v git &>/dev/null; then
  warn "git not found — some tools may fail"
else
  ok "git $(git --version | awk '{print $3}')"
fi

# ── Dry-run exit ───────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  sep
  echo -e "  ${YELLOW}Dry-run mode — no installs performed.${RESET}"
  sep
  exit 0
fi

# ── Node.js dependencies ───────────────────────────────────────────────────────
step "📦 Installing Node.js dependencies ($PKG_MGR install)"

# Honor the nested pnpm workspace
if [ "$PKG_MGR" = "pnpm" ] && [ -f "pnpm-workspace.yaml" ]; then
  ok "pnpm workspace detected"
fi

# Use --ignore-scripts so pnpm/npm never tries to execute postinstall
# (which calls bin/postinstall.mjs — a file that may not exist yet in fresh clones).
# We run Python setup explicitly below with full output control.
if [ "$PKG_MGR" = "pnpm" ]; then
  pnpm install --ignore-scripts || {
    warn "pnpm install --ignore-scripts failed — retrying with npm --ignore-scripts"
    npm install --ignore-scripts || die "npm install failed. Check the output above."
  }
else
  npm install --ignore-scripts || die "npm install failed. Check the output above."
fi
ok "Node.js dependencies installed"

# ── Python dependencies & local inference setup ────────────────────────────────
if [ -n "$PYTHON_EXE" ]; then
  SETUP_ARGS=()
  [ "$SKIP_MODEL"      = "1" ] && SETUP_ARGS+=("--skip-model")
  [ "$SKIP_LLAMA"      = "1" ] && SETUP_ARGS+=("--skip-llama")
  [ "$SKIP_PLAYWRIGHT" = "1" ] && SETUP_ARGS+=("--skip-playwright")

  if [ -f "bin/setup.py" ]; then
    step "🦙 Running local inference setup (bin/setup.py)"
    "$PYTHON_EXE" bin/setup.py "${SETUP_ARGS[@]}" || \
      warn "setup.py completed with warnings — check output above"
  else
    # ── Inline fallback when bin/setup.py is not present ──
    step "🦙 Installing Python inference dependencies"
    "$PYTHON_EXE" -m pip install --upgrade pip --quiet
    "$PYTHON_EXE" -m pip install --upgrade huggingface-hub || warn "huggingface-hub install failed"

    if [ "$SKIP_LLAMA" != "1" ]; then
      info "Building llama-cpp-python for: $GPU_NAME"
      if [ -n "$CMAKE_ARGS" ]; then
        info "CMAKE_ARGS=$CMAKE_ARGS"
        CMAKE_ARGS="$CMAKE_ARGS" "$PYTHON_EXE" -m pip install "llama-cpp-python[server]>=0.3.4" || {
          warn "GPU build failed — falling back to CPU-only build"
          "$PYTHON_EXE" -m pip install "llama-cpp-python[server]>=0.3.4"
        }
      else
        "$PYTHON_EXE" -m pip install "llama-cpp-python[server]>=0.3.4" || \
          warn "llama-cpp-python install failed — run: pip install 'llama-cpp-python[server]'"
      fi
    fi

    if [ "$SKIP_PLAYWRIGHT" != "1" ] && command -v npx &>/dev/null; then
      info "Installing Playwright system dependencies…"
      npx playwright install --with-deps 2>/dev/null || {
        warn "playwright --with-deps failed — trying without --with-deps"
        npx playwright install || warn "Playwright install incomplete"
      }
    fi
  fi
else
  warn "Python not found — skipping local inference setup"
  warn "Install Python 3.10+ then re-run: bash install.sh"
fi

# ── Final summary ──────────────────────────────────────────────────────────────
sep
echo -e "  ${GREEN}${BOLD}OpenClaw installation complete!${RESET}"
sep
echo -e "  ${BOLD}Platform${RESET} : $OS ($ARCH)"
echo -e "  ${BOLD}GPU${RESET}      : $GPU_NAME"
echo -e "  ${BOLD}Node.js${RESET}  : $(node --version 2>/dev/null || echo 'not found')"
echo -e "  ${BOLD}Python${RESET}   : ${PYTHON_VERSION:-not found}"
echo ""
echo -e "  ${BOLD}Start the inference server:${RESET}"
echo -e "    ${CYAN}python scripts/llama_cpp_server.py${RESET}"
echo ""
echo -e "  ${BOLD}Or with vision support:${RESET}"
echo -e "    ${CYAN}python scripts/llama_cpp_server.py --vision${RESET}"
echo ""
echo -e "  ${BOLD}Then start OpenClaw:${RESET}"
echo -e "    ${CYAN}npm start   (or: pnpm start)${RESET}"
sep
