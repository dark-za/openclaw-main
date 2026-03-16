#!/usr/bin/env python3
"""
OpenClaw local inference setup
================================
Run by install.sh inside the project venv (never the system Python).
Also safe to run standalone:

    python bin/setup.py              # full setup
    python bin/setup.py --skip-model     # skip GGUF download
    python bin/setup.py --skip-llama     # skip llama-cpp-python
    python bin/setup.py --skip-playwright  # skip Playwright

Environment variables
---------------------
OPENCLAW_VENV_DIR      Path to the venv (e.g. ~/.openclaw/venv)
OPENCLAW_VENV_PIP      Explicit pip executable inside venv
OPENCLAW_SETUP_VERBOSE Set to '1' for full pip output
HF_TOKEN               HuggingFace token (private models)
"""
from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

# ── Colour output ──────────────────────────────────────────────────────────────
_NO_COLOR = os.environ.get("NO_COLOR") or not sys.stdout.isatty()

def _c(code: str, t: str) -> str:
    return t if _NO_COLOR else f"\033[{code}m{t}\033[0m"

green  = lambda t: _c("32", t)
yellow = lambda t: _c("33", t)
red    = lambda t: _c("31", t)
cyan   = lambda t: _c("36", t)
bold   = lambda t: _c("1",  t)

PREFIX = bold(cyan("[openclaw-setup]"))
def step(e: str, m: str): print(f"\n{PREFIX} {e}  {bold(m)}", flush=True)
def ok(m: str):   print(f"  {green('✓')} {m}", flush=True)
def warn(m: str): print(f"  {yellow('⚠')} {m}", flush=True)
def die(m: str, hint: str = ""):
    print(f"\n{red('✗ Error:')} {m}", file=sys.stderr, flush=True)
    if hint: print(f"  {yellow('Hint:')} {hint}", file=sys.stderr)
    sys.exit(1)

# ── Constants ──────────────────────────────────────────────────────────────────
MIN_PYTHON       = (3, 10)
RECOMMENDED_REPO = "bartowski/Llama-3.2-3B-Instruct-GGUF"
RECOMMENDED_FILE = "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
MODELS_DIR       = Path.home() / ".openclaw" / "models"
VENV_DIR         = Path(os.environ.get("OPENCLAW_VENV_DIR", str(Path.home() / ".openclaw" / "venv")))

# ── Detect the pip to use ──────────────────────────────────────────────────────
# Priority: env override → venv pip → current interpreter's pip
def find_pip() -> str:
    # 1. Explicit env override from install.sh
    env_pip = os.environ.get("OPENCLAW_VENV_PIP")
    if env_pip and Path(env_pip).exists():
        return env_pip
    # 2. venv pip (standard location)
    venv_pip = VENV_DIR / "bin" / "pip"
    if venv_pip.exists():
        return str(venv_pip)
    # 3. Current interpreter's pip module
    return sys.executable + " -m pip (module)"

def _pip_install(
    packages: list[str],
    env: dict[str, str] | None = None,
    verbose: bool = False,
) -> bool:
    # Prefer the venv pip binary; fall back to the current interpreter's -m pip
    venv_pip_bin = VENV_DIR / "bin" / "pip"
    env_pip = os.environ.get("OPENCLAW_VENV_PIP")

    if env_pip and Path(env_pip).exists():
        cmd = [env_pip, "install", "--upgrade", *packages]
    elif venv_pip_bin.exists():
        cmd = [str(venv_pip_bin), "install", "--upgrade", *packages]
    else:
        # Fallback: current interpreter with -m pip
        cmd = [sys.executable, "-m", "pip", "install", "--upgrade", *packages]

    merged = {**os.environ, **(env or {})}
    if verbose:
        print(f"    $ {' '.join(cmd)}", flush=True)
        return subprocess.run(cmd, env=merged).returncode == 0
    else:
        result = subprocess.run(cmd, capture_output=True, text=True, env=merged)
        if result.returncode != 0:
            for line in reversed(result.stderr.splitlines()):
                line = line.strip()
                if line and not line.startswith("WARNING"):
                    warn(f"pip: {line}"); break
        return result.returncode == 0

# ── Version checks ─────────────────────────────────────────────────────────────
def check_python():
    step("🐍", "Checking Python version")
    v = sys.version_info[:2]
    if v < MIN_PYTHON:
        die(f"Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]}+ required (found {v[0]}.{v[1]})",
            hint="Install Python 3.10+: https://python.org/downloads")
    ok(f"Python {sys.version.split()[0]}")

# ── GPU detection ──────────────────────────────────────────────────────────────
class GpuInfo:
    def __init__(self, kind: str, name: str):
        self.kind = kind; self.name = name

    @property
    def cmake_args(self) -> str:
        return {
            "cuda":  "-DGGML_CUDA=on",
            "metal": "-DGGML_METAL=on",
            "rocm":  "-DGGML_HIPBLAS=on",
        }.get(self.kind, "")

def detect_gpu() -> GpuInfo:
    if platform.system() == "Darwin" and "arm" in (platform.processor() or ""):
        return GpuInfo("metal", "Apple Silicon (Metal)")
    try:
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=8)
        if r.returncode == 0 and r.stdout.strip():
            return GpuInfo("cuda", r.stdout.strip().splitlines()[0])
    except (FileNotFoundError, subprocess.TimeoutExpired): pass
    try:
        r = subprocess.run(["rocm-smi", "--showproductname"],
                           capture_output=True, text=True, timeout=8)
        if r.returncode == 0 and r.stdout.strip():
            lines = [l for l in r.stdout.splitlines() if "Card" in l or "GPU" in l]
            return GpuInfo("rocm", lines[0].strip() if lines else "AMD GPU (ROCm)")
    except (FileNotFoundError, subprocess.TimeoutExpired): pass
    return GpuInfo("none", "CPU-only")

# ── llama-cpp-python ───────────────────────────────────────────────────────────
def install_llama_cpp(gpu: GpuInfo, verbose: bool) -> None:
    step("🦙", "Installing llama-cpp-python")
    ok(f"Target: {gpu.name}")

    build_env: dict[str, str] = {}
    if gpu.cmake_args:
        build_env["CMAKE_ARGS"] = gpu.cmake_args
        ok(f"Build flags: CMAKE_ARGS={gpu.cmake_args!r}")
    else:
        ok("Build flags: none (CPU)")

    print(f"  {yellow('⏳')} Building… (2–10 min first time)", flush=True)
    pkg = "llama-cpp-python[server]>=0.3.4"
    if not _pip_install([pkg], env=build_env, verbose=verbose):
        if gpu.kind != "none":
            warn("GPU build failed — falling back to CPU build")
            if not _pip_install([pkg], verbose=verbose):
                die("llama-cpp-python install failed", hint="Run manually: pip install 'llama-cpp-python[server]'")
        else:
            die("llama-cpp-python install failed", hint="Run manually: pip install 'llama-cpp-python[server]'")
    ok("llama-cpp-python installed")

# ── huggingface-hub ────────────────────────────────────────────────────────────
def install_hf_hub(verbose: bool) -> None:
    step("🤗", "Installing huggingface-hub")
    if not _pip_install(["huggingface-hub>=0.24.0"], verbose=verbose):
        warn("huggingface-hub install failed — model download will not work")
    else:
        ok("huggingface-hub installed")

# ── Model download ─────────────────────────────────────────────────────────────
def download_model() -> None:
    step("📦", f"Downloading GGUF model ({RECOMMENDED_FILE})")
    dest = MODELS_DIR / RECOMMENDED_FILE
    if dest.exists():
        ok(f"Already present: {dest}"); return
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        warn("huggingface-hub not importable — skipping download"); return

    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    print(f"  {yellow('⏳')} Downloading from {RECOMMENDED_REPO}…", flush=True)
    try:
        path = hf_hub_download(
            repo_id=RECOMMENDED_REPO, filename=RECOMMENDED_FILE,
            local_dir=str(MODELS_DIR), token=token or None)
        ok(f"Model saved: {path}")
    except KeyboardInterrupt:
        warn("Interrupted — re-run: bash bin/openclaw-llm.sh")
    except Exception as e:
        msg = str(e).lower()
        if any(x in msg for x in ("space", "memory")):
            warn(f"Disk error: {e}\n  Free up space and retry")
        elif any(x in msg for x in ("401", "403", "auth")):
            warn(f"Auth error — set HF_TOKEN env var: {e}")
        else:
            warn(f"Download failed: {e}\n  Retry: python scripts/llama_cpp_server.py")

# ── Playwright ─────────────────────────────────────────────────────────────────
def install_playwright(verbose: bool) -> None:
    step("🎭", "Installing Playwright browser dependencies")
    npx = shutil.which("npx") or shutil.which("npx.cmd")
    if not npx:
        warn("npx not found — skipping Playwright"); return
    cmd = [npx, "playwright", "install", "--with-deps"]
    result = subprocess.run(cmd if verbose else cmd,
                            capture_output=not verbose, text=True)
    if result.returncode != 0:
        cmd2 = [npx, "playwright", "install"]
        result2 = subprocess.run(cmd2, capture_output=True, text=True)
        if result2.returncode == 0:
            ok("Playwright browsers installed (run 'sudo npx playwright install-deps' for system deps)")
        else:
            warn("Playwright install incomplete — run: npx playwright install --with-deps")
    else:
        ok("Playwright browsers and system deps installed")

# ── Summary ────────────────────────────────────────────────────────────────────
def print_summary(gpu: GpuInfo, skip_model: bool) -> None:
    print(f"\n{'─' * 52}", flush=True)
    print(f"  {green(bold('Local inference setup complete'))}", flush=True)
    print(f"{'─' * 52}", flush=True)
    print(f"  GPU  : {gpu.name}", flush=True)
    print(f"  venv : {VENV_DIR}", flush=True)
    if not skip_model:
        dest = MODELS_DIR / RECOMMENDED_FILE
        status = green("ready") if dest.exists() else yellow("pending")
        print(f"  Model: {RECOMMENDED_FILE} [{status}]", flush=True)
    print(f"\n  {cyan('bash bin/openclaw-llm.sh')}", flush=True)
    print(f"{'─' * 52}\n", flush=True)

# ── Main ───────────────────────────────────────────────────────────────────────
def main() -> None:
    # CI: auto-skip heavy steps
    is_ci = any(os.environ.get(v) == "true" for v in ("CI", "GITHUB_ACTIONS", "DOCKER_BUILD"))

    parser = argparse.ArgumentParser(description="OpenClaw local inference setup")
    parser.add_argument("--skip-model",      action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_SKIP_MODEL") == "1" or is_ci)
    parser.add_argument("--skip-llama",      action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_SKIP_LLAMA") == "1")
    parser.add_argument("--skip-playwright", action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_SKIP_PLAYWRIGHT") == "1" or is_ci)
    parser.add_argument("--verbose", "-v",   action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_VERBOSE") == "1")
    args = parser.parse_args()

    check_python()

    step("🔍", "Detecting GPU")
    gpu = detect_gpu()
    ok(f"{gpu.name} ({gpu.kind})")

    install_hf_hub(args.verbose)

    if not args.skip_llama:
        install_llama_cpp(gpu, args.verbose)
    else:
        step("🦙", "llama-cpp-python"); warn("Skipped (--skip-llama)")

    if not args.skip_model:
        download_model()
    else:
        step("📦", "Model download"); warn("Skipped (--skip-model)")

    if not args.skip_playwright:
        install_playwright(args.verbose)
    else:
        step("🎭", "Playwright"); warn("Skipped (--skip-playwright)")

    print_summary(gpu, args.skip_model)

if __name__ == "__main__":
    main()
