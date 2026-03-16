#!/usr/bin/env bash
# =============================================================================
# OpenClaw — Smart Installation Script (Linux / macOS)
# Compatible: Ubuntu 18+, Debian 10+, Fedora 38+, Arch, CentOS/RHEL 8+, macOS
# =============================================================================
# Usage:
#   bash install.sh                    # full install (recommended)
#   bash install.sh --skip-model       # skip GGUF model download
#   bash install.sh --skip-llama       # skip llama-cpp-python
#   bash install.sh --skip-playwright  # skip Playwright browser deps
#   bash install.sh --dry-run          # detect only, no installs
#
# Environment overrides:
#   OPENCLAW_VENV_DIR              path to Python venv   (default: ~/.openclaw/venv)
#   OPENCLAW_SETUP_SKIP_MODEL=1    skip model download
#   OPENCLAW_SETUP_SKIP_LLAMA=1    skip llama-cpp-python
#   OPENCLAW_SETUP_SKIP_PLAYWRIGHT=1  skip Playwright
#   HF_TOKEN                       HuggingFace token (private models)
# =============================================================================
set -euo pipefail

# ── Colour & output ────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1 && [ "$(tput colors)" -ge 8 ] 2>/dev/null; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

PREFIX="${BOLD}${CYAN}[openclaw]${RESET}"
step()  { echo -e "\n${PREFIX} ${BOLD}$*${RESET}"; }
ok()    { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
die()   { echo -e "\n${RED}✗ Fatal:${RESET} $*" >&2; exit 1; }
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
echo -e "  ${BOLD}${CYAN}OpenClaw${RESET} — Cross-Platform Smart Installer"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
sep

# ── CI auto-detection ──────────────────────────────────────────────────────────
if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "${DOCKER_BUILD:-}" = "true" ]; then
  warn "CI environment — auto-skipping heavy steps"
  SKIP_MODEL=1; SKIP_PLAYWRIGHT=1
fi

# ── Locate the project root ────────────────────────────────────────────────────
find_project_root() {
  local start_dir
  start_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Priority order: this dir → one level up → one level down → CWD
  for candidate in \
    "$start_dir" \
    "$(dirname "$start_dir")" \
    "$PWD"
  do
    [ -f "$candidate/package.json" ] && echo "$candidate" && return 0
  done
  for subdir in "$start_dir"/*/; do
    [ -f "$subdir/package.json" ] && echo "${subdir%/}" && return 0
  done
  return 1
}

step "📂 Locating project root"
PROJECT_ROOT="$(find_project_root)" || die \
  "Could not find package.json.\n  Try: cd openclaw-main && bash install.sh"
ok "Project root: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# ── venv directory ─────────────────────────────────────────────────────────────
VENV_DIR="${OPENCLAW_VENV_DIR:-$HOME/.openclaw/venv}"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# ── System detection ───────────────────────────────────────────────────────────
step "🖥  Detecting system"
OS="$(uname -s)"
ARCH="$(uname -m)"
ok "OS: $OS  Arch: $ARCH"

if [ "$OS" = "Darwin" ]; then
  ok "macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
fi
if [ "$OS" = "Linux" ] && [ -f /etc/os-release ]; then
  DISTRO_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
  ok "Distro: $DISTRO_NAME"
fi

MEM_GB=0
if command -v free &>/dev/null; then
  MEM_GB=$(( $(free -m 2>/dev/null | awk '/^Mem:/{print $2}') / 1024 ))
elif [ "$OS" = "Darwin" ]; then
  MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
fi
[ "$MEM_GB" -gt 0 ] && ok "RAM: ~${MEM_GB} GB"
ok "CPUs: $(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo '?') logical cores"

# ── GPU detection ──────────────────────────────────────────────────────────────
step "🔍 Detecting hardware accelerator"
GPU_KIND="none"; GPU_NAME="CPU-only"; CMAKE_ARGS=""

if command -v nvidia-smi &>/dev/null; then
  NVIDIA_OUT="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || true)"
  if [ -n "$NVIDIA_OUT" ]; then
    GPU_KIND="cuda"; GPU_NAME="$NVIDIA_OUT"; CMAKE_ARGS="-DGGML_CUDA=on"
    ok "NVIDIA GPU: $GPU_NAME"
    ok "CUDA: $(nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>/dev/null | head -1 || echo 'unknown')"
  fi
fi

if [ "$GPU_KIND" = "none" ] && [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then
  GPU_KIND="metal"; GPU_NAME="Apple Silicon (Metal)"; CMAKE_ARGS="-DGGML_METAL=on"
  ok "Metal (Apple Silicon)"
fi

if [ "$GPU_KIND" = "none" ] && command -v rocm-smi &>/dev/null; then
  ROCM_OUT="$(rocm-smi --showproductname 2>/dev/null | grep -i 'card\|gpu' | head -1 || true)"
  if [ -n "$ROCM_OUT" ]; then
    GPU_KIND="rocm"; GPU_NAME="$ROCM_OUT"; CMAKE_ARGS="-DGGML_HIPBLAS=on"
    ok "AMD ROCm GPU: $GPU_NAME"
  fi
fi

[ "$GPU_KIND" = "none" ] && warn "No GPU — CPU-only inference"

# ── Prerequisite: Node.js ──────────────────────────────────────────────────────
step "🔧 Checking Node.js"
MIN_NODE_MAJOR=22; MIN_NODE_MINOR=16; NODE_OK=0

if command -v node &>/dev/null; then
  NODE_VERSION="$(node --version | tr -d 'v')"
  NODE_MAJOR="$(echo "$NODE_VERSION" | cut -d. -f1)"
  NODE_MINOR="$(echo "$NODE_VERSION" | cut -d. -f2)"
  if [ "$NODE_MAJOR" -gt "$MIN_NODE_MAJOR" ] || \
     { [ "$NODE_MAJOR" -eq "$MIN_NODE_MAJOR" ] && [ "$NODE_MINOR" -ge "$MIN_NODE_MINOR" ]; }; then
    ok "Node.js v$NODE_VERSION"; NODE_OK=1
  else
    warn "Node.js v$NODE_VERSION found — need ≥v${MIN_NODE_MAJOR}.${MIN_NODE_MINOR}.0"
  fi
fi

if [ "$NODE_OK" = "0" ]; then
  info "Installing Node.js via nvm…"
  if [ ! -f "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
  # shellcheck disable=SC1090
  source "$HOME/.nvm/nvm.sh"
  nvm install "$MIN_NODE_MAJOR"
  nvm alias default "$MIN_NODE_MAJOR"
  ok "Node.js $(node --version)"
fi

# ── Prerequisite: package manager ─────────────────────────────────────────────
PKG_MGR="npm"
if command -v pnpm &>/dev/null; then
  PKG_MGR="pnpm"; ok "pnpm $(pnpm --version)"
else
  ok "npm $(npm --version)"
  if command -v corepack &>/dev/null; then
    info "Enabling pnpm via corepack…"
    corepack enable pnpm 2>/dev/null && \
    corepack prepare pnpm@latest --activate 2>/dev/null && \
    PKG_MGR="pnpm" && ok "pnpm $(pnpm --version)" || true
  fi
  if [ "$PKG_MGR" = "npm" ]; then
    info "Installing pnpm globally…"
    npm install -g pnpm 2>/dev/null && PKG_MGR="pnpm" && ok "pnpm $(pnpm --version)" || \
      warn "pnpm unavailable — using npm"
  fi
fi

# ── Prerequisite: Python ───────────────────────────────────────────────────────
step "🐍 Checking Python"
MIN_PY_MAJOR=3; MIN_PY_MINOR=10
SYSTEM_PYTHON=""

for candidate in python3 python python3.13 python3.12 python3.11 python3.10; do
  if command -v "$candidate" &>/dev/null; then
    VER="$($candidate -c 'import sys; v=sys.version_info; print(f"{v.major}.{v.minor}.{v.micro}")' 2>/dev/null || echo "")"
    if [ -n "$VER" ]; then
      MAJ="$(echo "$VER" | cut -d. -f1)"; MIN2="$(echo "$VER" | cut -d. -f2)"
      if [ "$MAJ" -gt "$MIN_PY_MAJOR" ] || \
         { [ "$MAJ" -eq "$MIN_PY_MAJOR" ] && [ "$MIN2" -ge "$MIN_PY_MINOR" ]; }; then
        SYSTEM_PYTHON="$candidate"
        ok "System Python: $VER ($candidate)"; break
      fi
    fi
  fi
done

if [ -z "$SYSTEM_PYTHON" ]; then
  warn "Python $MIN_PY_MAJOR.$MIN_PY_MINOR+ not found — attempting auto-install"
  if [ "$OS" = "Linux" ]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get update -qq
      sudo apt-get install -y python3 python3-venv python3-full
      SYSTEM_PYTHON="python3"
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y python3; SYSTEM_PYTHON="python3"
    elif command -v pacman &>/dev/null; then
      sudo pacman -Sy --noconfirm python; SYSTEM_PYTHON="python3"
    elif command -v zypper &>/dev/null; then
      sudo zypper install -y python3; SYSTEM_PYTHON="python3"
    fi
  elif [ "$OS" = "Darwin" ] && command -v brew &>/dev/null; then
    brew install python@3.12; SYSTEM_PYTHON="python3"
  fi
  [ -z "$SYSTEM_PYTHON" ] && warn "Python not found — skipping Python setup"
fi

# ── Prerequisite: python3-venv system package (Ubuntu/Debian) ─────────────────
if [ -n "$SYSTEM_PYTHON" ] && [ "$OS" = "Linux" ]; then
  # Test if venv module works — it may be split into python3.X-venv on Ubuntu
  if ! "$SYSTEM_PYTHON" -m venv --help &>/dev/null 2>&1; then
    warn "python3-venv not available — installing"
    if command -v apt-get &>/dev/null; then
      PY_VER_SHORT="$($SYSTEM_PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
      sudo apt-get install -y "python${PY_VER_SHORT}-venv" python3-venv python3-full 2>/dev/null || \
        sudo apt-get install -y python3-venv python3-full
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y python3-virtualenv
    fi
  fi
fi

# ── Create Python virtual environment ─────────────────────────────────────────
# This is the correct, PEP 668-compliant approach for all modern Linux distros.
# We install ALL Python packages (llama-cpp-python, huggingface-hub, etc.)
# inside this venv — never into the system Python.
if [ -n "$SYSTEM_PYTHON" ]; then
  step "🐍 Creating Python virtual environment"
  info "Location: $VENV_DIR"

  if [ -f "$VENV_PYTHON" ]; then
    ok "venv already exists — reusing"
  else
    mkdir -p "$(dirname "$VENV_DIR")"
    "$SYSTEM_PYTHON" -m venv "$VENV_DIR" || die \
      "Failed to create venv at $VENV_DIR\n  Try: apt-get install python3-venv"
    ok "venv created at $VENV_DIR"
  fi

  # Upgrade pip *inside the venv* (no PEP 668 restriction here)
  "$VENV_PIP" install --upgrade pip setuptools wheel --quiet
  ok "pip $($VENV_PIP --version | awk '{print $2}') (inside venv)"

  # Write a convenience wrapper so the server always uses the venv Python
  mkdir -p "$PROJECT_ROOT/bin"
  cat > "$PROJECT_ROOT/bin/openclaw-llm.sh" << LAUNCHER
#!/usr/bin/env bash
# Auto-generated by install.sh — starts the llama-cpp-python inference server
# using the correct Python venv.
VENV_PYTHON="$VENV_PYTHON"
SCRIPT="\$(cd "\$(dirname "\$0")/.." && pwd)/scripts/llama_cpp_server.py"
if [ ! -f "\$VENV_PYTHON" ]; then
  echo "Error: venv not found at $VENV_DIR — re-run: bash install.sh" >&2
  exit 1
fi
exec "\$VENV_PYTHON" "\$SCRIPT" "\$@"
LAUNCHER
  chmod +x "$PROJECT_ROOT/bin/openclaw-llm.sh"
  ok "Launcher: bin/openclaw-llm.sh"
fi

# ── Prerequisite: C++ compiler ─────────────────────────────────────────────────
step "🔨 Checking C++ compiler"
if command -v gcc &>/dev/null || command -v clang &>/dev/null; then
  CC_EXE="$(command -v gcc || command -v clang)"
  ok "Compiler: $($CC_EXE --version 2>/dev/null | head -1)"
else
  warn "No C++ compiler — needed for llama-cpp-python GPU build"
  if [ "$OS" = "Linux" ] && command -v apt-get &>/dev/null; then
    info "Installing build-essential cmake…"
    sudo apt-get install -y build-essential cmake
    ok "build-essential installed"
  elif [ "$OS" = "Linux" ] && command -v dnf &>/dev/null; then
    sudo dnf groupinstall -y "Development Tools"; sudo dnf install -y cmake
  elif [ "$OS" = "Darwin" ]; then
    xcode-select --install 2>/dev/null || true
    warn "Re-run install.sh after Xcode CLT finishes"
  fi
fi

if ! command -v cmake &>/dev/null; then
  warn "cmake not found"
  command -v apt-get &>/dev/null && sudo apt-get install -y cmake && ok "cmake installed" || true
  command -v brew &>/dev/null && brew install cmake && ok "cmake installed" || true
fi

command -v git &>/dev/null && ok "git $(git --version | awk '{print $3}')" || warn "git not found"

# ── Dry-run exit ───────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  sep; echo -e "  ${YELLOW}Dry-run — nothing installed.${RESET}"; sep; exit 0
fi

# ── Node.js dependencies ───────────────────────────────────────────────────────
step "📦 Installing Node.js dependencies"
[ "$PKG_MGR" = "pnpm" ] && [ -f "pnpm-workspace.yaml" ] && ok "pnpm workspace detected"

# --ignore-scripts: never let pnpm/npm run postinstall during this phase.
# The postinstall references bin/postinstall.mjs which may not exist in fresh
# clones. We run Python setup explicitly below instead.
if [ "$PKG_MGR" = "pnpm" ]; then
  pnpm install --ignore-scripts || {
    warn "pnpm failed — retrying with npm"
    npm install --ignore-scripts || die "npm install failed. See output above."
  }
else
  npm install --ignore-scripts || die "npm install failed. See output above."
fi
ok "Node.js dependencies installed"

# ── Python packages inside venv ────────────────────────────────────────────────
if [ -n "$SYSTEM_PYTHON" ] && [ -f "$VENV_PYTHON" ]; then

  SETUP_ARGS=()
  [ "$SKIP_MODEL"      = "1" ] && SETUP_ARGS+=("--skip-model")
  [ "$SKIP_LLAMA"      = "1" ] && SETUP_ARGS+=("--skip-llama")
  [ "$SKIP_PLAYWRIGHT" = "1" ] && SETUP_ARGS+=("--skip-playwright")

  if [ -f "$PROJECT_ROOT/bin/setup.py" ]; then
    # Run the bootstrap *with the venv Python* so all installs go into the venv
    step "🦙 Running local inference setup"
    OPENCLAW_VENV_DIR="$VENV_DIR" \
    OPENCLAW_VENV_PYTHON="$VENV_PYTHON" \
    OPENCLAW_VENV_PIP="$VENV_PIP" \
      "$VENV_PYTHON" "$PROJECT_ROOT/bin/setup.py" "${SETUP_ARGS[@]}" || \
      warn "setup.py completed with warnings — check output above"
  else
    # Inline fallback
    step "🦙 Installing Python inference dependencies (venv)"
    info "Installing huggingface-hub…"
    "$VENV_PIP" install --upgrade huggingface-hub --quiet || warn "huggingface-hub failed"

    if [ "$SKIP_LLAMA" != "1" ]; then
      info "Building llama-cpp-python for: $GPU_NAME"
      [ -n "$CMAKE_ARGS" ] && info "CMAKE_ARGS=$CMAKE_ARGS"
      CMAKE_ARGS="${CMAKE_ARGS}" "$VENV_PIP" install "llama-cpp-python[server]>=0.3.4" || {
        warn "GPU build failed — retrying CPU-only"
        "$VENV_PIP" install "llama-cpp-python[server]>=0.3.4" || \
          warn "llama-cpp-python failed — run manually: $VENV_PIP install 'llama-cpp-python[server]'"
      }
    fi

    if [ "$SKIP_PLAYWRIGHT" != "1" ] && command -v npx &>/dev/null; then
      info "Installing Playwright browsers…"
      npx playwright install --with-deps 2>/dev/null || \
        npx playwright install || warn "Playwright install incomplete"
    fi
  fi

else
  warn "Python venv not available — skipping local inference setup"
  warn "Install Python 3.10+ and re-run: bash install.sh"
fi

# ── Final summary ──────────────────────────────────────────────────────────────
sep
echo -e "  ${GREEN}${BOLD}OpenClaw installation complete!${RESET}"
sep
echo -e "  ${BOLD}Platform ${RESET}: $OS ($ARCH)"
echo -e "  ${BOLD}GPU      ${RESET}: $GPU_NAME"
echo -e "  ${BOLD}Node.js  ${RESET}: $(node --version 2>/dev/null || echo 'n/a')"
echo -e "  ${BOLD}Python   ${RESET}: $($VENV_PYTHON --version 2>/dev/null || echo 'n/a') [venv: $VENV_DIR]"
echo ""
echo -e "  ${BOLD}${CYAN}Start local inference:${RESET}"
echo -e "    bash bin/openclaw-llm.sh"
echo ""
echo -e "  ${BOLD}${CYAN}Then start OpenClaw:${RESET}"
echo -e "    npm start   (or: pnpm start)"
sep
