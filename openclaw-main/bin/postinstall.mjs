#!/usr/bin/env node
/**
 * bin/postinstall.mjs
 *
 * Node.js shim invoked by the `postinstall` lifecycle hook in package.json.
 * Delegates to bin/setup.py, handling all the Python-discovery edge-cases
 * that trip up cross-platform installs (Windows, macOS, Linux).
 *
 * Design constraints:
 *  • Must use only Node.js built-ins (no npm dependencies — postinstall runs
 *    before dependencies are resolved in some install scenarios).
 *  • Should never hard-fail the npm/pnpm install on non-critical setup errors
 *    (e.g. missing Python, GPU driver issues). Warns and exits 0 instead.
 *  • Respects OPENCLAW_SKIP_SETUP=1 to allow clean CI builds that don't need
 *    local inference.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { platform } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const SETUP_PY = join(ROOT, "bin", "setup.py");

const NO_COLOR = !process.stdout.isTTY;
const c = (code, t) => (NO_COLOR ? t : `\x1b[${code}m${t}\x1b[0m`);
const cyan   = (t) => c("36", t);
const yellow = (t) => c("33", t);
const bold   = (t) => c("1",  t);
const prefix = bold(cyan("[openclaw-setup]"));

function log(msg)  { console.log(`${prefix} ${msg}`); }
function warn(msg) { console.warn(`${prefix} ${yellow("⚠")}  ${msg}`); }

// ── Skip guard ─────────────────────────────────────────────────────────────────
if (process.env.OPENCLAW_SKIP_SETUP === "1") {
  log("OPENCLAW_SKIP_SETUP=1 — skipping local inference setup.");
  process.exit(0);
}

// ── Verify setup.py exists ─────────────────────────────────────────────────────
if (!existsSync(SETUP_PY)) {
  warn(`bin/setup.py not found at ${SETUP_PY} — skipping setup.`);
  process.exit(0);
}

// ── Find a working Python interpreter ─────────────────────────────────────────
function findPython() {
  const candidates =
    platform() === "win32"
      ? ["python", "python3", "py"]
      : ["python3", "python"];

  for (const candidate of candidates) {
    try {
      const result = spawnSync(candidate, ["-c", "import sys; print(sys.version_info[:2])"], {
        encoding: "utf8",
        timeout: 5000,
      });
      if (result.status === 0 && result.stdout.trim()) {
        // Parse "(major, minor)" e.g. "(3, 12)"
        const match = result.stdout.trim().match(/(\d+),\s*(\d+)/);
        if (match) {
          const [, major, minor] = match.map(Number);
          if (major > 3 || (major === 3 && minor >= 10)) {
            return candidate;
          } else {
            warn(`${candidate} is Python ${major}.${minor} — need 3.10+, skipping`);
          }
        }
      }
    } catch {
      // not found
    }
  }
  return null;
}

const pythonExe = findPython();

if (!pythonExe) {
  warn("Python 3.10+ not found. Skipping local inference setup.");
  warn("Install Python 3.10+ from https://python.org/downloads then run:");
  warn("  python bin/setup.py");
  // Exit 0: don't block the Node install for missing Python
  process.exit(0);
}

// ── Log detected Python ────────────────────────────────────────────────────────
try {
  const ver = execFileSync(pythonExe, ["--version"], { encoding: "utf8" }).trim();
  log(`Using: ${ver} (${pythonExe})`);
} catch {
  // ignore
}

// ── Build setup.py argument list from env vars / npm lifecycle flags ──────────
const args = [SETUP_PY];

// Propagate env-controlled skip flags as CLI args for clearer log output
if (process.env.OPENCLAW_SETUP_SKIP_MODEL === "1")      args.push("--skip-model");
if (process.env.OPENCLAW_SETUP_SKIP_PLAYWRIGHT === "1") args.push("--skip-playwright");
if (process.env.OPENCLAW_SETUP_SKIP_LLAMA === "1")      args.push("--skip-llama");
if (process.env.OPENCLAW_SETUP_VERBOSE === "1")         args.push("--verbose");

log(`Running: ${pythonExe} ${args.join(" ")}`);

// ── Execute setup.py ───────────────────────────────────────────────────────────
const result = spawnSync(pythonExe, args, {
  stdio: "inherit",   // pipe all output directly to the terminal
  env: process.env,
  cwd: ROOT,
});

if (result.error) {
  warn(`Failed to spawn setup.py: ${result.error.message}`);
  warn("Run manually: python bin/setup.py");
  // Don't fail npm install for setup errors
  process.exit(0);
}

if (result.status !== 0) {
  warn(`bin/setup.py exited with code ${result.status}.`);
  warn("Local inference setup incomplete — run manually: python bin/setup.py");
  // Non-zero from setup.py is a setup warning, not a hard install error
  process.exit(0);
}
