#!/usr/bin/env python3
"""
OpenClaw local inference setup
================================
Selects, downloads, and installs the right LLM for your hardware.

Usage:
    python bin/setup.py                   # interactive model selection
    python bin/setup.py --auto            # auto-select best model for hardware
    python bin/setup.py --model 2         # pick model #2 from catalog (no prompt)
    python bin/setup.py --model-repo bartowski/Llama-3.1-8B-Instruct-GGUF \\
                         --model-file Llama-3.1-8B-Instruct-Q4_K_M.gguf
    python bin/setup.py --skip-model      # skip model download
    python bin/setup.py --skip-llama      # skip llama-cpp-python
    python bin/setup.py --skip-playwright # skip Playwright

Environment variables:
    OPENCLAW_VENV_DIR       path to Python venv   (default: ~/.openclaw/venv)
    OPENCLAW_VENV_PIP       venv pip executable
    OPENCLAW_SETUP_SKIP_MODEL=1     skip download
    OPENCLAW_SETUP_SKIP_LLAMA=1     skip llama-cpp-python
    OPENCLAW_SETUP_SKIP_PLAYWRIGHT=1  skip Playwright
    OPENCLAW_SETUP_VERBOSE=1        verbose pip output
    HF_TOKEN                HuggingFace token (private/faster downloads)
"""
from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

# ── Colour helpers ─────────────────────────────────────────────────────────────
_NO_COLOR = bool(os.environ.get("NO_COLOR") or not sys.stdout.isatty())

def _c(code: str, t: str) -> str:
    return t if _NO_COLOR else f"\033[{code}m{t}\033[0m"

green  = lambda t: _c("32", t)
yellow = lambda t: _c("33", t)
red    = lambda t: _c("31", t)
cyan   = lambda t: _c("36", t)
bold   = lambda t: _c("1",  t)
dim    = lambda t: _c("2",  t)

PREFIX = bold(cyan("[openclaw-setup]"))
def step(e: str, m: str): print(f"\n{PREFIX} {e}  {bold(m)}", flush=True)
def ok(m: str):   print(f"  {green('✓')} {m}", flush=True)
def warn(m: str): print(f"  {yellow('⚠')} {m}", flush=True)
def info(m: str): print(f"  {cyan('→')} {m}", flush=True)
def die(m: str, hint: str = ""):
    print(f"\n{red('✗ Error:')} {m}", file=sys.stderr, flush=True)
    if hint: print(f"  {yellow('Hint:')} {hint}", file=sys.stderr)
    sys.exit(1)

# ── Constants ──────────────────────────────────────────────────────────────────
MIN_PYTHON = (3, 10)
MODELS_DIR = Path.home() / ".openclaw" / "models"
VENV_DIR   = Path(os.environ.get("OPENCLAW_VENV_DIR",
                                  str(Path.home() / ".openclaw" / "venv")))

# ── Model catalog ──────────────────────────────────────────────────────────────
class ModelEntry(NamedTuple):
    label:    str          # Human-readable display name
    repo:     str          # HuggingFace repo ID
    file:     str          # GGUF filename
    size_gb:  float        # Approximate download size (GB)
    ram_gb:   int          # Minimum recommended RAM (GB) to run
    vram_gb:  int          # Minimum VRAM (GPU) needed; 0 = CPU-only fine
    tier:     str          # "tiny" | "small" | "medium" | "large"

MODEL_CATALOG: list[ModelEntry] = [
    ModelEntry(
        label   = "Qwen2.5-0.5B  │ tiny     │ ~380 MB  │ min 2 GB RAM",
        repo    = "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
        file    = "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        size_gb = 0.38, ram_gb = 2, vram_gb = 0, tier = "tiny",
    ),
    ModelEntry(
        label   = "Llama-3.2-1B  │ tiny     │ ~800 MB  │ min 2 GB RAM",
        repo    = "bartowski/Llama-3.2-1B-Instruct-GGUF",
        file    = "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
        size_gb = 0.77, ram_gb = 2, vram_gb = 0, tier = "tiny",
    ),
    ModelEntry(
        label   = "Llama-3.2-3B  │ small    │ ~2.0 GB  │ min 4 GB RAM  ★ recommended CPU",
        repo    = "bartowski/Llama-3.2-3B-Instruct-GGUF",
        file    = "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        size_gb = 2.0, ram_gb = 4, vram_gb = 0, tier = "small",
    ),
    ModelEntry(
        label   = "Mistral-7B    │ medium   │ ~4.1 GB  │ min 8 GB RAM",
        repo    = "TheBloke/Mistral-7B-Instruct-v0.2-GGUF",
        file    = "mistral-7b-instruct-v0.2.Q4_K_M.gguf",
        size_gb = 4.1, ram_gb = 8, vram_gb = 6, tier = "medium",
    ),
    ModelEntry(
        label   = "Llama-3.1-8B  │ medium   │ ~4.9 GB  │ min 8 GB RAM  ★ recommended GPU",
        repo    = "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
        file    = "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
        size_gb = 4.9, ram_gb = 8, vram_gb = 6, tier = "medium",
    ),
    ModelEntry(
        label   = "Phi-3.5-mini  │ medium   │ ~2.2 GB  │ min 6 GB RAM  (Microsoft)",
        repo    = "bartowski/Phi-3.5-mini-instruct-GGUF",
        file    = "Phi-3.5-mini-instruct-Q4_K_M.gguf",
        size_gb = 2.2, ram_gb = 6, vram_gb = 4, tier = "small",
    ),
    ModelEntry(
        label   = "Gemma-2-9B    │ large    │ ~5.4 GB  │ min 10 GB RAM (Google)",
        repo    = "bartowski/gemma-2-9b-it-GGUF",
        file    = "gemma-2-9b-it-Q4_K_M.gguf",
        size_gb = 5.4, ram_gb = 10, vram_gb = 8, tier = "large",
    ),
    ModelEntry(
        label   = "Qwen2.5-14B   │ large    │ ~8.2 GB  │ min 16 GB RAM",
        repo    = "bartowski/Qwen2.5-14B-Instruct-GGUF",
        file    = "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
        size_gb = 8.2, ram_gb = 16, vram_gb = 10, tier = "large",
    ),
    ModelEntry(
        label   = "Custom model  │ enter your own HuggingFace repo + filename",
        repo    = "__custom__",
        file    = "__custom__",
        size_gb = 0.0, ram_gb = 0, vram_gb = 0, tier = "custom",
    ),
]

# ── Hardware detection ─────────────────────────────────────────────────────────
def get_available_ram_gb() -> int:
    """Return available system RAM in GB (total physical memory)."""
    try:
        if platform.system() == "Linux":
            import shlex
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        return int(line.split()[1]) // (1024 * 1024)
        elif platform.system() == "Darwin":
            out = subprocess.check_output(["sysctl", "-n", "hw.memsize"],
                                          text=True, timeout=3)
            return int(out.strip()) // (1024 ** 3)
    except Exception:
        pass
    return 8  # safe default

def get_gpu_vram_gb() -> tuple[str, int]:
    """Return (gpu_kind, vram_gb). vram_gb=0 means CPU-only or unknown."""
    # macOS Apple Silicon
    if platform.system() == "Darwin" and "arm" in (platform.processor() or ""):
        try:
            out = subprocess.check_output(
                ["system_profiler", "SPHardwareDataType"], text=True, timeout=5)
            for line in out.splitlines():
                if "Memory:" in line:
                    mem = int(line.strip().split()[1])
                    return ("metal", mem)
        except Exception:
            pass
        return ("metal", 8)  # safe default for Apple Silicon

    # NVIDIA
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,memory.total",
             "--format=csv,noheader"],
            text=True, timeout=8)
        lines = [l.strip() for l in out.strip().splitlines() if l.strip()]
        if lines:
            parts = lines[0].split(",")
            name  = parts[0].strip()
            mem_s = parts[1].strip().split()[0] if len(parts) > 1 else "0"
            vram_gb = int(mem_s) // 1024
            return ("cuda", vram_gb)
    except (FileNotFoundError, subprocess.TimeoutExpired, ValueError, IndexError):
        pass

    # AMD ROCm
    try:
        out = subprocess.check_output(
            ["rocm-smi", "--showproductname"], text=True, timeout=8)
        if out.strip():
            return ("rocm", 8)  # VRAM unknown; assume 8 GB
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return ("none", 0)

class HardwareProfile(NamedTuple):
    ram_gb:    int
    gpu_kind:  str
    vram_gb:   int
    label:     str

def detect_hardware() -> HardwareProfile:
    ram      = get_available_ram_gb()
    gk, vram = get_gpu_vram_gb()
    effective = max(ram, vram)
    if gk == "cuda":
        label = f"RAM {ram} GB | NVIDIA GPU {vram} GB VRAM"
    elif gk == "metal":
        label = f"RAM {ram} GB | Apple Silicon (Metal)"
    elif gk == "rocm":
        label = f"RAM {ram} GB | AMD GPU {vram} GB (ROCm)"
    else:
        label = f"RAM {ram} GB | CPU-only"
    return HardwareProfile(ram, gk, vram, label)

def recommend_model(hw: HardwareProfile) -> int:
    """
    Return the 0-based catalog index of the best model for this hardware.
    Uses GPU VRAM when available, otherwise RAM.
    """
    capacity = hw.vram_gb if hw.gpu_kind != "none" and hw.vram_gb > 0 else hw.ram_gb
    # Pick the most capable model that fits within the effective capacity
    best_idx = 0  # fallback: first (smallest)
    for i, m in enumerate(MODEL_CATALOG):
        if m.tier == "custom":
            continue
        if hw.gpu_kind != "none":
            fits = m.vram_gb <= capacity or m.vram_gb == 0
        else:
            fits = m.ram_gb <= capacity
        if fits:
            best_idx = i
    return best_idx

# ── Interactive model selection menu ──────────────────────────────────────────
def show_model_menu(hw: HardwareProfile, auto_idx: int) -> ModelEntry:
    """
    Print an interactive numbered menu and return the selected ModelEntry.
    If stdin is not a TTY (piped/CI) or reading fails, returns the auto-suggested model.
    """
    sep = "─" * 62
    print(f"\n{bold(sep)}", flush=True)
    print(f"  {bold(cyan('OpenClaw — Model Selection'))}", flush=True)
    print(f"  Hardware: {hw.label}", flush=True)
    print(f"{bold(sep)}", flush=True)

    for i, m in enumerate(MODEL_CATALOG):
        prefix = f"  {bold(green(str(i+1)))}." if i != len(MODEL_CATALOG)-1 else f"  {bold(green(str(i+1)))}."
        # Mark recommended
        if i == auto_idx:
            tag = f" {bold(yellow('← auto-recommended'))}"
        else:
            # Dim models that don't fit
            fits = (hw.vram_gb >= m.vram_gb or hw.gpu_kind == "none") and hw.ram_gb >= m.ram_gb
            tag  = "" if fits else f" {dim('(may not fit your RAM)')}"
        print(f"{prefix} {m.label}{tag}", flush=True)

    print(f"{bold(sep)}", flush=True)
    print(f"  Press {bold('Enter')} to accept [{bold(green(str(auto_idx+1)))}], or type a number: ",
          end="", flush=True)

    if not sys.stdin.isatty():
        print(flush=True)
        ok(f"Non-interactive — auto-selecting #{auto_idx+1}")
        return MODEL_CATALOG[auto_idx]

    try:
        raw = input().strip()
    except (EOFError, KeyboardInterrupt):
        print(flush=True)
        ok(f"Auto-selecting #{auto_idx+1}")
        return MODEL_CATALOG[auto_idx]

    if not raw:
        return MODEL_CATALOG[auto_idx]

    try:
        choice = int(raw) - 1
        if 0 <= choice < len(MODEL_CATALOG):
            return MODEL_CATALOG[choice]
        warn(f"Invalid choice '{raw}' — using auto-recommendation")
        return MODEL_CATALOG[auto_idx]
    except ValueError:
        warn(f"Invalid input '{raw}' — using auto-recommendation")
        return MODEL_CATALOG[auto_idx]

def prompt_custom_model() -> tuple[str, str]:
    """Ask the user for a custom HuggingFace repo + filename."""
    print(f"\n  {bold('Custom model — HuggingFace URL format:')}", flush=True)
    print(f"  {dim('Example: bartowski/Llama-3.1-8B-Instruct-GGUF')}", flush=True)

    print(f"  {cyan('Repo ID')} :  ", end="", flush=True)
    repo = input().strip() if sys.stdin.isatty() else ""
    if not repo:
        die("No repo ID entered — aborting model download",
            hint="Re-run: python bin/setup.py")

    print(f"  {cyan('Filename')} : ", end="", flush=True)
    fname = input().strip() if sys.stdin.isatty() else ""
    if not fname:
        die("No filename entered — aborting model download",
            hint="Re-run: python bin/setup.py")

    return repo, fname

# ── pip helper ─────────────────────────────────────────────────────────────────
def _find_pip() -> list[str]:
    """Return the pip command as a list, preferring the venv pip."""
    env_pip = os.environ.get("OPENCLAW_VENV_PIP")
    if env_pip and Path(env_pip).exists():
        return [env_pip]
    venv_pip = VENV_DIR / "bin" / "pip"
    if venv_pip.exists():
        return [str(venv_pip)]
    return [sys.executable, "-m", "pip"]

def _pip_install(packages: list[str],
                 env: dict[str, str] | None = None,
                 verbose: bool = False) -> bool:
    cmd = [*_find_pip(), "install", "--upgrade", *packages]
    merged = {**os.environ, **(env or {})}
    if verbose:
        print(f"    $ {' '.join(cmd)}", flush=True)
        return subprocess.run(cmd, env=merged).returncode == 0
    result = subprocess.run(cmd, capture_output=True, text=True, env=merged)
    if result.returncode != 0:
        for line in reversed(result.stderr.splitlines()):
            line = line.strip()
            if line and not line.startswith("WARNING"):
                warn(f"pip: {line}"); break
    return result.returncode == 0

# ── GPU detection (for llama-cpp-python build) ─────────────────────────────────
class GpuInfo:
    def __init__(self, kind: str, name: str):
        self.kind = kind; self.name = name

    @property
    def cmake_args(self) -> str:
        return {"cuda": "-DGGML_CUDA=on",
                "metal": "-DGGML_METAL=on",
                "rocm": "-DGGML_HIPBLAS=on"}.get(self.kind, "")

def detect_gpu_for_build() -> GpuInfo:
    if platform.system() == "Darwin" and "arm" in (platform.processor() or ""):
        return GpuInfo("metal", "Apple Silicon (Metal)")
    try:
        r = subprocess.run(["nvidia-smi", "--query-gpu=name",
                            "--format=csv,noheader"],
                           capture_output=True, text=True, timeout=8)
        if r.returncode == 0 and r.stdout.strip():
            return GpuInfo("cuda", r.stdout.strip().splitlines()[0])
    except (FileNotFoundError, subprocess.TimeoutExpired): pass
    try:
        r = subprocess.run(["rocm-smi", "--showproductname"],
                           capture_output=True, text=True, timeout=8)
        if r.returncode == 0 and r.stdout.strip():
            return GpuInfo("rocm", "AMD GPU (ROCm)")
    except (FileNotFoundError, subprocess.TimeoutExpired): pass
    return GpuInfo("none", "CPU-only")

# ── llama-cpp-python installation ─────────────────────────────────────────────
def install_llama_cpp(gpu: GpuInfo, verbose: bool) -> None:
    step("🦙", "Installing llama-cpp-python")
    ok(f"Target: {gpu.name}")
    build_env: dict[str, str] = {}
    if gpu.cmake_args:
        build_env["CMAKE_ARGS"] = gpu.cmake_args
        ok(f"Build flags: {gpu.cmake_args}")
    else:
        ok("Build flags: none (CPU build)")
    print(f"  {yellow('⏳')} Building llama-cpp-python… (2–10 min first time)", flush=True)
    pkg = "llama-cpp-python[server]>=0.3.4"
    if not _pip_install([pkg], env=build_env, verbose=verbose):
        if gpu.kind != "none":
            warn("GPU build failed — retrying with CPU-only build")
            if not _pip_install([pkg], verbose=verbose):
                die("llama-cpp-python install failed",
                    hint=f"Manual: {' '.join(_find_pip())} install 'llama-cpp-python[server]'")
        else:
            die("llama-cpp-python install failed",
                hint=f"Manual: {' '.join(_find_pip())} install 'llama-cpp-python[server]'")
    ok("llama-cpp-python installed ✓")

# ── huggingface-hub ────────────────────────────────────────────────────────────
def install_hf_hub(verbose: bool) -> None:
    step("🤗", "Installing huggingface-hub")
    if not _pip_install(["huggingface-hub>=0.24.0"], verbose=verbose):
        warn("huggingface-hub failed — model download will not work")
    else:
        ok("huggingface-hub installed")

# ── Model download ─────────────────────────────────────────────────────────────
def download_model(repo: str, filename: str) -> None:
    dest = MODELS_DIR / filename
    if dest.exists():
        ok(f"Already downloaded: {filename}"); return
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        warn("huggingface-hub not importable — skipping download"); return

    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if not token:
        info("Tip: set HF_TOKEN for faster (unauthenticated) rate limits bypass")
    print(f"  {yellow('⏳')} Downloading {filename}\n"
          f"  {dim(f'From: {repo}')}", flush=True)
    try:
        path = hf_hub_download(repo_id=repo, filename=filename,
                               local_dir=str(MODELS_DIR), token=token or None)
        ok(f"Model saved → {path}")
    except KeyboardInterrupt:
        print(flush=True)
        warn("Download interrupted — partial file kept")
        warn(f"Resume later: python scripts/llama_cpp_server.py")
    except Exception as e:
        msg = str(e).lower()
        if any(x in msg for x in ("space", "disk", "memory")):
            warn(f"Disk/memory error: {e}")
            warn("Free disk space then retry")
        elif any(x in msg for x in ("401", "403", "auth", "private")):
            warn(f"Auth error: {e}")
            warn("Set HF_TOKEN: export HF_TOKEN=hf_xxx...")
        else:
            warn(f"Download failed: {e}")
        warn(f"Retry: HF_TOKEN=<token> python bin/setup.py")

# ── Playwright ─────────────────────────────────────────────────────────────────
def install_playwright(verbose: bool) -> None:
    step("🎭", "Installing Playwright browser dependencies")
    npx = shutil.which("npx") or shutil.which("npx.cmd")
    if not npx:
        warn("npx not found — skipping Playwright"); return
    cmd = [npx, "playwright", "install", "--with-deps"]
    try:
        result = subprocess.run(cmd, capture_output=not verbose, text=not verbose)
        if result.returncode != 0:
            info("Retrying without --with-deps (may need sudo separately)")
            result2 = subprocess.run([npx, "playwright", "install"],
                                     capture_output=not verbose, text=not verbose)
            if result2.returncode == 0:
                ok("Playwright browsers installed")
                warn("Run manually for system deps: sudo npx playwright install-deps")
            else:
                warn("Playwright install incomplete — run: npx playwright install --with-deps")
        else:
            ok("Playwright browsers and system deps installed")
    except KeyboardInterrupt:
        print(flush=True)
        warn("Playwright install interrupted — run later: npx playwright install --with-deps")

# ── Summary ────────────────────────────────────────────────────────────────────
def print_summary(hw: HardwareProfile, gpu: GpuInfo,
                  model_file: str | None, skip_model: bool) -> None:
    sep = "─" * 54
    print(f"\n{bold(sep)}", flush=True)
    print(f"  {green(bold('OpenClaw local inference — setup complete'))}", flush=True)
    print(f"{bold(sep)}", flush=True)
    print(f"  Hardware : {hw.label}", flush=True)
    print(f"  Build    : {gpu.name}", flush=True)
    print(f"  venv     : {VENV_DIR}", flush=True)
    if not skip_model and model_file:
        dest = MODELS_DIR / model_file
        status = green("ready") if dest.exists() else yellow("incomplete — re-run to finish")
        print(f"  Model    : {model_file} [{status}]", flush=True)
    print(f"\n  {bold(cyan('Start inference server:'))}", flush=True)
    print(f"    bash bin/openclaw-llm.sh", flush=True)
    print(f"\n  {bold(cyan('Or directly with venv Python:'))}", flush=True)
    print(f"    {VENV_DIR}/bin/python scripts/llama_cpp_server.py", flush=True)
    print(f"{bold(sep)}\n", flush=True)

# ── Main ───────────────────────────────────────────────────────────────────────
def main() -> None:
    is_ci = any(os.environ.get(v) == "true" for v in ("CI", "GITHUB_ACTIONS", "DOCKER_BUILD"))

    parser = argparse.ArgumentParser(
        description="OpenClaw — local inference setup with hardware-aware model selection",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--auto", action="store_true",
                        help="Auto-select best model for hardware — no interactive prompt")
    parser.add_argument("--model", type=int, metavar="N",
                        help="Select model N from the catalog (1-based, use with --auto)")
    parser.add_argument("--model-repo", metavar="REPO",
                        help="Custom HuggingFace repo ID (use with --model-file)")
    parser.add_argument("--model-file", metavar="FILE",
                        help="Custom GGUF filename within the repo")
    parser.add_argument("--skip-model", action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_SKIP_MODEL") == "1" or is_ci)
    parser.add_argument("--skip-llama", action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_SKIP_LLAMA") == "1")
    parser.add_argument("--skip-playwright", action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_SKIP_PLAYWRIGHT") == "1" or is_ci)
    parser.add_argument("--verbose", "-v", action="store_true",
                        default=os.environ.get("OPENCLAW_SETUP_VERBOSE") == "1")
    args = parser.parse_args()

    # ── Python version check ──
    v = sys.version_info[:2]
    if v < MIN_PYTHON:
        die(f"Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]}+ required (found {v[0]}.{v[1]})")

    # ── Hardware detection ──
    step("🔍", "Detecting hardware")
    hw  = detect_hardware()
    gpu = detect_gpu_for_build()
    ok(hw.label)

    # ── llama-cpp-python ──
    if not args.skip_llama:
        install_hf_hub(args.verbose)
        install_llama_cpp(gpu, args.verbose)
    else:
        step("🦙", "llama-cpp-python"); warn("Skipped (--skip-llama)")

    # ── Model selection ──
    chosen_repo: str | None = None
    chosen_file: str | None = None

    if not args.skip_model:
        step("🗂 ", "Model selection")

        # Priority 1: explicit --model-repo + --model-file
        if args.model_repo and args.model_file:
            chosen_repo = args.model_repo
            chosen_file = args.model_file
            ok(f"Custom: {chosen_repo} / {chosen_file}")

        # Priority 2: --model N (numbered catalog)
        elif args.model is not None:
            idx = args.model - 1
            if 0 <= idx < len(MODEL_CATALOG):
                entry = MODEL_CATALOG[idx]
                if entry.tier == "custom":
                    chosen_repo, chosen_file = prompt_custom_model()
                else:
                    chosen_repo = entry.repo
                    chosen_file = entry.file
                ok(f"Selected #{args.model}: {entry.file}")
            else:
                warn(f"Invalid --model {args.model} — falling back to interactive menu")
                args.model = None

        # Priority 3: auto (CI or --auto flag)
        if chosen_repo is None and (args.auto or is_ci or not sys.stdin.isatty()):
            auto_idx = recommend_model(hw)
            entry = MODEL_CATALOG[auto_idx]
            if entry.tier != "custom":
                chosen_repo = entry.repo
                chosen_file = entry.file
                ok(f"Auto-selected: {entry.label.split('│')[0].strip()}")
            else:
                warn("Auto-selected 'custom' — falling back to default")
                entry = MODEL_CATALOG[2]  # Llama-3.2-3B
                chosen_repo = entry.repo
                chosen_file = entry.file

        # Priority 4: interactive menu
        if chosen_repo is None:
            auto_idx = recommend_model(hw)
            entry = show_model_menu(hw, auto_idx)
            if entry.tier == "custom":
                chosen_repo, chosen_file = prompt_custom_model()
            else:
                chosen_repo = entry.repo
                chosen_file = entry.file
                ok(f"Selected: {entry.label.split('│')[0].strip()}")
                info(f"Size: ~{entry.size_gb} GB  |  Min RAM: {entry.ram_gb} GB")

        # ── Download ──
        if chosen_repo and chosen_file:
            step("📦", f"Downloading {chosen_file}")
            download_model(chosen_repo, chosen_file)
    else:
        step("📦", "Model download"); warn("Skipped (--skip-model)")
        chosen_file = None

    # ── Playwright ──
    if not args.skip_playwright:
        install_playwright(args.verbose)
    else:
        step("🎭", "Playwright"); warn("Skipped (--skip-playwright)")

    print_summary(hw, gpu, chosen_file, args.skip_model)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n\n{yellow('Setup interrupted')} — re-run: python bin/setup.py", flush=True)
        sys.exit(0)
