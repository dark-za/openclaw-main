#!/usr/bin/env bash
# =============================================================================
# OpenClaw — Unified Startup Script
# Starts llama-cpp inference server (background) then the OpenClaw gateway.
# =============================================================================
# Usage:
#   bash bin/openclaw-start.sh             # start everything
#   bash bin/openclaw-start.sh --no-llm    # skip llama-cpp server
#   bash bin/openclaw-start.sh --llm-only  # inference server only (no gateway)
#   bash bin/openclaw-start.sh --stop      # stop llama-cpp server (by PID file)
# =============================================================================
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPENCLAW_STATE="$HOME/.openclaw"
ENV_FILE="$OPENCLAW_STATE/.env"
LLM_LOG="$OPENCLAW_STATE/llm.log"
LLM_PID_FILE="$OPENCLAW_STATE/llm.pid"
VENV_PYTHON="$OPENCLAW_STATE/venv/bin/python"
LLM_SCRIPT="$PROJECT_DIR/scripts/llama_cpp_server.py"

# ── Colour ────────────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi
ok()   { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
info() { echo -e "  ${CYAN}→${RESET}  $*"; }
sep()  { echo -e "${BOLD}──────────────────────────────────────────────────${RESET}"; }

# ── Flags ─────────────────────────────────────────────────────────────────────
NO_LLM=0; LLM_ONLY=0; DO_STOP=0
for arg in "$@"; do
  case "$arg" in
    --no-llm)   NO_LLM=1 ;;
    --llm-only) LLM_ONLY=1 ;;
    --stop)     DO_STOP=1 ;;
  esac
done

# ── Stop ──────────────────────────────────────────────────────────────────────
if [ "$DO_STOP" = "1" ]; then
  if [ -f "$LLM_PID_FILE" ]; then
    PID="$(cat "$LLM_PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID" && ok "llama-cpp server (PID $PID) stopped"
    else
      warn "PID $PID not running"
    fi
    rm -f "$LLM_PID_FILE"
  else
    warn "No PID file found — server may not be running"
  fi
  exit 0
fi

sep
echo -e "  ${BOLD}${CYAN}OpenClaw — Starting${RESET}"
sep

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  ok "Loaded ~/.openclaw/.env"
else
  warn "~/.openclaw/.env not found"
  warn "Run 'bash install.sh' to generate gateway auth token"
  warn "Or manually: echo 'OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)' > ~/.openclaw/.env"
fi

# ── llama-cpp inference server ────────────────────────────────────────────────
if [ "$NO_LLM" = "0" ]; then
  if [ -f "$VENV_PYTHON" ] && [ -f "$LLM_SCRIPT" ]; then
    # Check if already running
    if [ -f "$LLM_PID_FILE" ] && kill -0 "$(cat "$LLM_PID_FILE")" 2>/dev/null; then
      ok "llama-cpp server already running (PID $(cat "$LLM_PID_FILE"))"
    else
      info "Starting llama-cpp inference server on :8765 (background)…"
      "$VENV_PYTHON" "$LLM_SCRIPT" > "$LLM_LOG" 2>&1 &
      LLM_PID=$!
      echo "$LLM_PID" > "$LLM_PID_FILE"
      ok "llama-cpp server started (PID $LLM_PID)"
      info "Log: tail -f $LLM_LOG"
      # Give server 2 seconds to start up
      sleep 2
    fi
  else
    warn "llama-cpp venv not found — skipping inference server"
    info "Run 'bash install.sh' to set up local inference"
  fi
fi

if [ "$LLM_ONLY" = "1" ]; then
  echo ""
  ok "Inference server running — dashboard: http://127.0.0.1:8765/v1"
  exit 0
fi

# ── OpenClaw gateway ──────────────────────────────────────────────────────────
info "Starting OpenClaw gateway → http://127.0.0.1:18789/"
sep
cd "$PROJECT_DIR"

# Try the installed CLI first, then pnpm/npm dev server
if command -v openclaw &>/dev/null; then
  exec openclaw start
elif [ -f "dist/cli.js" ]; then
  exec node --enable-source-maps dist/cli.js start
elif command -v pnpm &>/dev/null; then
  exec pnpm start
else
  exec npm start
fi
