#!/usr/bin/env bash
# itx-doctor.sh -- cross-platform shell entry to itx-doctor for machines
# where install.sh doesn't apply (macOS, non-Ubuntu Linux).
#
# Bootstraps a minimal toolchain (Python + claude CLI + marketplace +
# itx-doctor plugin), then invokes the doctor engine with any flags
# passed on the command line.
#
# Usage:
#   ./itx-doctor.sh             # default: prompt-to-fix per gap
#   ./itx-doctor.sh --no-fix    # audit only
#   ./itx-doctor.sh --yes       # unattended fix
#   ./itx-doctor.sh --json      # machine-readable
#
# License: MIT.

set -euo pipefail
IFS=$'\n\t'

# ─── Logging helpers (mirror install.sh) ───────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi
info() { printf '       %s\n' "$1"; }
ok()   { printf '%s[ok]%s   %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

# ─── Detect OS ──────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin)  OS=macos ;;
  Linux)   OS=linux ;;
  *)       fail "Unsupported OS: $(uname -s). Use install.sh on Linux/WSL or itx-doctor.ps1 on Windows."
           exit 1 ;;
esac

# ─── Ensure Python ──────────────────────────────────────────────────────────
if ! command -v python >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  info "Python not on PATH; installing..."
  case "$OS" in
    macos)
      if ! command -v brew >/dev/null 2>&1; then
        fail "Homebrew not installed. Install from https://brew.sh first, then re-run itx-doctor.sh."
        exit 1
      fi
      brew install python
      ;;
    linux)
      if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3
      elif command -v apt-get >/dev/null 2>&1; then
        # Shouldn't reach here -- install.sh covers this -- but be safe.
        sudo apt-get update -qq && sudo apt-get install -y python3 python-is-python3
      else
        fail "No supported package manager (dnf/apt). Install Python manually and re-run."
        exit 1
      fi
      ;;
  esac
fi
PY="$(command -v python3 || command -v python)"
ok "Python: $PY"

# ─── Ensure claude CLI ──────────────────────────────────────────────────────
if ! command -v claude >/dev/null 2>&1; then
  info "claude CLI not on PATH; installing via native installer..."
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
  hash -r
fi
ok "claude: $(claude --version)"

# ─── Ensure marketplace registered ──────────────────────────────────────────
if ! claude plugin marketplace list --json 2>/dev/null | "$PY" -c \
     "import sys,json; sys.exit(0 if any(p.get('name')=='itx-claude-marketplace' for p in json.load(sys.stdin)) else 1)"; then
  info "Registering itx-claude-marketplace..."
  claude plugin marketplace add https://github.com/screpeau-itc/itx-claude-marketplace
fi

# ─── Ensure itx-doctor plugin installed ─────────────────────────────────────
if ! claude plugin list 2>/dev/null | grep -q "itx-doctor"; then
  info "Installing itx-doctor plugin..."
  claude plugin install itx-doctor@itx-claude-marketplace
fi

DOCTOR_PY="$("$PY" -c "from pathlib import Path; print(str(Path.home() / '.claude' / 'plugins' / 'marketplaces' / 'itx-claude-marketplace' / 'plugins' / 'itx-doctor' / 'bin' / 'itx_doctor.py'))")"
if [[ ! -f "$DOCTOR_PY" ]]; then
  fail "itx-doctor plugin not found at $DOCTOR_PY after install"
  exit 1
fi

# ─── Invoke ──────────────────────────────────────────────────────────────────
exec "$PY" "$DOCTOR_PY" "$@"
