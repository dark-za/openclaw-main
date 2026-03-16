#!/usr/bin/env python3
"""
OpenClaw llama-cpp-python sidecar server
=========================================
Starts llama-cpp-python's built-in OpenAI-compatible HTTP server on
http://127.0.0.1:8765/v1, which OpenClaw connects to as the "llama-cpp"
provider (same pattern as the vLLM / SGLang integrations).

Usage
-----
  # Text model (auto-downloads on first run):
  python scripts/llama_cpp_server.py

  # Vision model (LLaVA / Moondream — auto-downloads):
  python scripts/llama_cpp_server.py --vision

  # Custom model from HuggingFace:
  python scripts/llama_cpp_server.py \\
      --model-repo bartowski/Llama-3.1-8B-Instruct-GGUF \\
      --model-file Llama-3.1-8B-Instruct-Q4_K_M.gguf

  # Use a local GGUF file (skips download):
  LLAMA_CPP_MODEL_PATH=/path/to/model.gguf python scripts/llama_cpp_server.py

Environment overrides
---------------------
  LLAMA_CPP_MODEL_PATH   Local GGUF path (bypasses HuggingFace download)
  LLAMA_CPP_MMPROJ_PATH  Local CLIP projector GGUF path (vision mode)
  LLAMA_CPP_PORT         Override server port (default: 8765)
  LLAMA_CPP_N_GPU_LAYERS Override GPU offload layers (-1 = all, 0 = CPU-only)
"""

from __future__ import annotations

import argparse
import os
import platform
import subprocess
import sys
from pathlib import Path

# ── venv auto-bootstrap ───────────────────────────────────────────────────────
# If run with the system Python (e.g. `python3 scripts/llama_cpp_server.py`),
# automatically re-exec inside the OpenClaw venv so llama_cpp is importable.
# This makes the script work regardless of which Python the user invokes.
_VENV_DIR = Path(os.environ.get("OPENCLAW_VENV_DIR", str(Path.home() / ".openclaw" / "venv")))
_VENV_PYTHON = _VENV_DIR / "bin" / "python"

if _VENV_PYTHON.exists() and Path(sys.executable).resolve() != _VENV_PYTHON.resolve():
    # Re-exec with venv Python, preserving all arguments
    os.execv(str(_VENV_PYTHON), [str(_VENV_PYTHON)] + sys.argv)
# ── end venv bootstrap ────────────────────────────────────────────────────────

# ── Defaults ──────────────────────────────────────────────────────────────────────────────

DEFAULT_MODEL_REPO = "bartowski/Llama-3.2-3B-Instruct-GGUF"
DEFAULT_MODEL_FILE = "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
DEFAULT_PORT = int(os.environ.get("LLAMA_CPP_PORT", "8765"))
MODELS_DIR = Path.home() / ".openclaw" / "models"

# Vision-capable defaults — LLaVA 1.6 with Mistral 7B backbone
DEFAULT_VISION_REPO = "cjpais/llava-1.6-mistral-7b-gguf"
DEFAULT_VISION_FILE = "llava-1.6-mistral-7b.Q4_K_M.gguf"
DEFAULT_MMPROJ_FILE = "mmproj-model-f16.gguf"


# ── GPU detection ────────────────────────────────────────────────────────────────────────

def detect_n_gpu_layers() -> int:
    """
    Auto-detect available GPU acceleration and return the optimal n_gpu_layers:
      -1  → full offload (CUDA / Metal / ROCm — all layers on GPU)
       0  → CPU-only (safe fallback when no accelerator is found)

    Can be overridden via the LLAMA_CPP_N_GPU_LAYERS environment variable.
    """
    override = os.environ.get("LLAMA_CPP_N_GPU_LAYERS")
    if override is not None:
        return int(override)

    system = platform.system()

    if system == "Darwin":
        # Apple Silicon / macOS — Metal is always available; full offload
        return -1

    if system in ("Linux", "Windows"):
        # Check CUDA (NVIDIA)
        try:
            result = subprocess.run(
                ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                gpu_name = result.stdout.strip().splitlines()[0]
                print(f"[llama-cpp] CUDA GPU detected: {gpu_name}", flush=True)
                return -1
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

        # Check ROCm (AMD)
        try:
            result = subprocess.run(
                ["rocm-smi", "--showid"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                print("[llama-cpp] ROCm GPU detected", flush=True)
                return -1
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

    print("[llama-cpp] No GPU detected — using CPU-only inference", flush=True)
    return 0


# ── Model download / resolution ───────────────────────────────────────────────────────────

def ensure_model(repo: str, filename: str, models_dir: Path) -> Path:
    """
    Resolve the local path to a GGUF model file.
    Downloads from HuggingFace Hub if the file is not already present.

    Priority:
      1. LLAMA_CPP_MODEL_PATH env var (skips download entirely)
      2. Cached file under models_dir
      3. Fresh download via huggingface-hub

    Raises
    ------
    FileNotFoundError  – LLAMA_CPP_MODEL_PATH set but path doesn't exist
    RuntimeError       – huggingface-hub not installed or OOM/disk error
    """
    local_override = os.environ.get("LLAMA_CPP_MODEL_PATH")
    if local_override:
        path = Path(local_override)
        if not path.exists():
            raise FileNotFoundError(
                f"LLAMA_CPP_MODEL_PATH does not exist: {path}"
            )
        print(f"[llama-cpp] Using local model override: {path}", flush=True)
        return path

    models_dir.mkdir(parents=True, exist_ok=True)
    dest = models_dir / filename

    if dest.exists():
        print(f"[llama-cpp] Model already cached: {dest}", flush=True)
        return dest

    print(
        f"[llama-cpp] Downloading {filename} from {repo} …",
        flush=True,
    )
    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        raise RuntimeError(
            "huggingface_hub is not installed.\n"
            "Run:  pip install huggingface-hub"
        )

    try:
        downloaded = hf_hub_download(
            repo_id=repo,
            filename=filename,
            local_dir=str(models_dir),
        )
        path = Path(downloaded)
        print(f"[llama-cpp] Download complete: {path}", flush=True)
        return path

    except Exception as exc:
        msg = str(exc).lower()
        if any(keyword in msg for keyword in ("out of memory", "oom", "no space left")):
            raise RuntimeError(
                f"[llama-cpp] OOM / disk-space error during download: {exc}\n\n"
                "Suggestions:\n"
                "  • Use a smaller quantisation (e.g. Q2_K instead of Q4_K_M)\n"
                "  • Free up disk space on the models directory\n"
                f"  • Set LLAMA_CPP_MODEL_PATH to point to an existing GGUF file"
            ) from exc
        raise


# ── Vision (CLIP) handler ────────────────────────────────────────────────────────────────

def build_vision_handler(mmproj_path: Path):
    """
    Return a llama_cpp chat_handler for multimodal/vision models.
    Compatible with LLaVA 1.5/1.6 and Moondream2.
    """
    try:
        from llama_cpp.llama_chat_format import Llava15ChatHandler
    except ImportError:
        raise RuntimeError(
            "llama-cpp-python[server] is not installed or missing vision support.\n"
            "Run:  pip install 'llama-cpp-python[server]'"
        )
    return Llava15ChatHandler(clip_model_path=str(mmproj_path), verbose=False)


# ── OOM error handling ────────────────────────────────────────────────────────────────────

def handle_oom(exc: Exception, n_gpu_layers: int) -> None:
    """Print a helpful OOM diagnostic and exit with code 1."""
    print(
        "\n[llama-cpp] ⚠️  Out of Memory error while loading the model.\n\n"
        "Suggestions:\n"
        "  1. Use a smaller quantisation (e.g. Q4_K_M → Q2_K)\n"
        f"  2. Reduce GPU offload: set LLAMA_CPP_N_GPU_LAYERS=20\n"
        f"     (currently: {n_gpu_layers})\n"
        "  3. Lower context window: --n-ctx 2048\n"
        "  4. Use a smaller model (e.g. 3B instead of 7B)\n",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)


# ── Server launch ────────────────────────────────────────────────────────────────────────

def launch_server(
    model_path: Path,
    port: int,
    n_gpu_layers: int,
    mmproj_path: Path | None = None,
    n_ctx: int = 8192,
    host: str = "127.0.0.1",
) -> None:
    """
    Load the GGUF model via llama-cpp-python and start the built-in
    OpenAI-compatible HTTP server. Blocks until the process is killed.
    """
    try:
        from llama_cpp import Llama
        import uvicorn
    except ImportError:
        raise RuntimeError(
            "llama-cpp-python[server] is not installed.\n"
            "Run:  pip install 'llama-cpp-python[server]'"
        )

    print(
        f"[llama-cpp] Loading model\n"
        f"  path         : {model_path}\n"
        f"  n_gpu_layers : {n_gpu_layers}"
        f" ({'full GPU offload' if n_gpu_layers == -1 else 'CPU-only' if n_gpu_layers == 0 else 'partial GPU offload'})\n"
        f"  n_ctx        : {n_ctx}\n"
        f"  vision       : {'yes (' + str(mmproj_path) + ')' if mmproj_path else 'no'}",
        flush=True,
    )

    llm_kwargs: dict = dict(
        model_path=str(model_path),
        n_gpu_layers=n_gpu_layers,
        n_ctx=n_ctx,
        verbose=False,
    )

    if mmproj_path:
        llm_kwargs["chat_handler"] = build_vision_handler(mmproj_path)

    try:
        llm = Llama(**llm_kwargs)
    except MemoryError as exc:
        handle_oom(exc, n_gpu_layers)
        return  # unreachable; handle_oom calls sys.exit(1)
    except Exception as exc:
        msg = str(exc).lower()
        if any(k in msg for k in ("out of memory", "oom", "cuda out of memory", "not enough memory")):
            handle_oom(exc, n_gpu_layers)
        raise

    try:
        from llama_cpp.server.app import create_app
    except ImportError:
        raise RuntimeError(
            "llama-cpp-python server module not found.\n"
            "Ensure you installed the [server] extra:\n"
            "  pip install 'llama-cpp-python[server]'"
        )

    app = create_app(llm=llm)
    print(
        f"\n[llama-cpp] ✅  Server ready  →  http://{host}:{port}/v1\n"
        f"  OpenClaw provider  : llama-cpp\n"
        f"  Models endpoint    : http://{host}:{port}/v1/models\n",
        flush=True,
    )
    uvicorn.run(app, host=host, port=port, log_level="warning")


# ── CLI ───────────────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Launch the llama-cpp-python OpenAI-compatible server for OpenClaw",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--model-repo",
        default=DEFAULT_MODEL_REPO,
        help=f"HuggingFace repo ID (default: {DEFAULT_MODEL_REPO})",
    )
    parser.add_argument(
        "--model-file",
        default=DEFAULT_MODEL_FILE,
        help=f"GGUF filename within the repo (default: {DEFAULT_MODEL_FILE})",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help="HTTP port to listen on (default: 8765, override: LLAMA_CPP_PORT)",
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Bind address (default: 127.0.0.1 — localhost only)",
    )
    parser.add_argument(
        "--n-ctx",
        type=int,
        default=8192,
        help="Context window size in tokens (default: 8192)",
    )
    parser.add_argument(
        "--vision",
        action="store_true",
        help="Load a LLaVA-compatible vision/multimodal model",
    )
    parser.add_argument(
        "--mmproj",
        default=None,
        help="Path to the CLIP multimodal projector GGUF (vision mode only)",
    )
    args = parser.parse_args()

    # ── resolve model ──
    if args.vision:
        repo = DEFAULT_VISION_REPO
        file = DEFAULT_VISION_FILE
    else:
        repo = args.model_repo
        file = args.model_file

    n_gpu_layers = detect_n_gpu_layers()
    print(
        f"[llama-cpp] Hardware acceleration: "
        f"{'full GPU offload (n_gpu_layers=-1)' if n_gpu_layers == -1 else 'CPU-only (n_gpu_layers=0)'}",
        flush=True,
    )

    model_path = ensure_model(repo, file, MODELS_DIR)

    # ── resolve mmproj (vision) ──
    mmproj_path: Path | None = None
    if args.vision:
        mmproj_env = os.environ.get("LLAMA_CPP_MMPROJ_PATH")
        if mmproj_env:
            mmproj_path = Path(mmproj_env)
        elif args.mmproj:
            mmproj_path = Path(args.mmproj)
        else:
            mmproj_path = ensure_model(DEFAULT_VISION_REPO, DEFAULT_MMPROJ_FILE, MODELS_DIR)

    launch_server(
        model_path=model_path,
        port=args.port,
        n_gpu_layers=n_gpu_layers,
        mmproj_path=mmproj_path,
        n_ctx=args.n_ctx,
        host=args.host,
    )


if __name__ == "__main__":
    main()
