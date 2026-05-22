#!/usr/bin/env bash
# itc-bootstrap — cold-start installer for Claude Code on Ubuntu/WSL
# See README.md for usage. Designed to be invoked via:
#   curl -fsSL https://raw.githubusercontent.com/screpeau-itc/itc-bootstrap/main/install.sh | bash
#
# Source: https://github.com/screpeau-itc/itc-bootstrap
# License: MIT (see LICENSE)

set -euo pipefail
IFS=$'\n\t'

# ─── Logging helpers ───────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

step_start() { printf '%s[%s]%s %s\n' "$C_BLUE$C_BOLD" "$1" "$C_RESET" "$2"; }
step_done()  { printf '%s[%s]%s %s✓ done%s\n' "$C_BLUE$C_BOLD" "$1" "$C_RESET" "$C_GREEN" "$C_RESET"; }
step_skip()  { printf '%s[%s]%s %s○ skipped%s (%s)\n' "$C_BLUE$C_BOLD" "$1" "$C_RESET" "$C_YELLOW" "$C_RESET" "$2"; }
step_fail()  { printf '%s[%s]%s %s✗ FAILED%s: %s\n' "$C_BLUE$C_BOLD" "$1" "$C_RESET" "$C_RED" "$C_RESET" "$2" >&2; }
info()       { printf '       %s\n' "$1"; }
prompt()     { printf '%s? %s%s ' "$C_BOLD" "$1" "$C_RESET"; }

# ─── Safety pre-flight ─────────────────────────────────────────────────────────

# Bash 4+ required (we use ${var,,} lowercasing, associative arrays, etc.).
# Target distros (Ubuntu/Debian) always ship bash 5+; this guard is for
# anyone who pastes the recipe on macOS (bash 3.2) or a stripped container.
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'itc-bootstrap: requires bash 4 or newer (detected bash %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  step_fail "preflight" "do not run this script as root; run as your normal user (the script sudos the steps that need elevation)"
  exit 1
fi

# ─── Detection ─────────────────────────────────────────────────────────────────

detect_distro() {
  if [[ ! -r /etc/os-release ]]; then
    echo "unknown"
    return
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "${ID:-unknown}"
}

detect_env() {
  local virt
  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    echo "wsl"
  elif [[ -f /.dockerenv ]] || grep -qE '(^|[/.-])docker([/.-]|$)' /proc/1/cgroup 2>/dev/null; then
    echo "docker"
  elif grep -qE '(^|[/.-])lxc([/.-]|$)' /proc/1/cgroup 2>/dev/null \
       || { command -v systemd-detect-virt >/dev/null 2>&1 \
            && [[ "$(systemd-detect-virt --container 2>/dev/null)" == "lxc" ]]; }; then
    echo "lxc"
  elif command -v systemd-detect-virt >/dev/null 2>&1; then
    virt=$(systemd-detect-virt 2>/dev/null || echo "none")
    if [[ "$virt" != "none" ]]; then
      echo "vm"
    else
      echo "native"
    fi
  else
    echo "native"
  fi
}

step_start "detect" "Detecting distro and environment"
DISTRO=$(detect_distro)
ENV_TYPE=$(detect_env)
info "Distro: $DISTRO"
info "Environment: $ENV_TYPE"

case "$DISTRO" in
  ubuntu|debian)
    step_done "detect"
    ;;
  *)
    step_fail "detect" "MVP supports Ubuntu/Debian only — detected '$DISTRO'"
    info "For other distros, see README.md § Manual mode."
    exit 1
    ;;
esac

# Default inbound-SSH choice based on env (overridable in prompts below):
case "$ENV_TYPE" in
  wsl|docker|lxc|vm) DEFAULT_INBOUND_SSH="y" ;;
  *)                  DEFAULT_INBOUND_SSH="n" ;;
esac

# ─── Front-loaded prompts ──────────────────────────────────────────────────────

# Verify we have an interactive tty for the prompts that follow.
# Under `curl ... | bash`, stdin is the script pipe — `read` would consume
# the script itself. We force reads from /dev/tty instead.
if [[ ! -e /dev/tty ]]; then
  step_fail "preflight" "interactive installer requires a TTY (/dev/tty missing); run from a real terminal"
  exit 1
fi

# Read with default. Args: prompt-text, default-value, var-name.
ask_with_default() {
  local p="$1" def="$2" var="$3" reply
  prompt "$p [default: $def]: "
  read -r reply < /dev/tty
  if [[ -z "$reply" ]]; then
    printf -v "$var" '%s' "$def"
  else
    printf -v "$var" '%s' "$reply"
  fi
}

# Yes/No with default. Args: prompt-text, default ("y" or "n"), var-name (set to "y" or "n").
ask_yes_no() {
  local p="$1" def="$2" var="$3" reply hint
  case "$def" in
    y) hint="[Y/n]" ;;
    n) hint="[y/N]" ;;
    *) hint="[y/n]" ;;
  esac
  while true; do
    prompt "$p $hint: "
    read -r reply < /dev/tty
    reply="${reply:-$def}"
    case "${reply,,}" in
      y|yes) printf -v "$var" 'y'; return ;;
      n|no)  printf -v "$var" 'n'; return ;;
      *) info "Please answer y or n." ;;
    esac
  done
}

echo
info "${C_BOLD}A few quick questions, then the installer runs uninterrupted until it needs interactive auth.${C_RESET}"
echo

ask_with_default "Workspace folder name (under ~/dev)" "itx-default-code" WORKSPACE_NAME
ask_yes_no       "Enable inbound SSH on this host (so you can SSH in from another machine)?" \
                 "$DEFAULT_INBOUND_SSH" INBOUND_SSH

# Folder name sanity: no slashes, no leading dot, non-empty
if [[ -z "$WORKSPACE_NAME" || "$WORKSPACE_NAME" == .* || "$WORKSPACE_NAME" == */* ]]; then
  step_fail "prompts" "invalid workspace name '$WORKSPACE_NAME' (must be non-empty, no slashes, no leading dot)"
  exit 1
fi

WORKSPACE_DIR="$HOME/dev/$WORKSPACE_NAME"

echo
info "Will use workspace: $WORKSPACE_DIR"
info "Inbound SSH:        $([[ "$INBOUND_SSH" == "y" ]] && echo "enabled" || echo "disabled")"
echo

# ─── [base-pkgs] Base packages ─────────────────────────────────────────────────

step_start "base-pkgs" "Installing base packages"

BASE_PACKAGES=(build-essential git ca-certificates gnupg lsb-release jq tmux unzip)

# Update apt index (quietly, but show errors)
sudo apt-get update -qq

# Install all in one apt invocation (handles already-installed automatically)
sudo apt-get install -y "${BASE_PACKAGES[@]}"

step_done "base-pkgs"

# ─── [wsl-conf] WSL overlay ────────────────────────────────────────────────────

if [[ "$ENV_TYPE" == "wsl" ]]; then
  step_start "wsl-conf" "Writing /etc/wsl.conf"

  WSL_CONF_NEW=$(cat <<'EOF'
[boot]
systemd=true

[user]
default=screpeau

[interop]
appendWindowsPath=false

[automount]
enabled=false
EOF
)

  if [[ -f /etc/wsl.conf ]] && diff -q <(echo "$WSL_CONF_NEW") /etc/wsl.conf >/dev/null 2>&1; then
    step_skip "wsl-conf" "/etc/wsl.conf already matches"
  else
    if [[ -f /etc/wsl.conf ]]; then
      BACKUP="/etc/wsl.conf.bak.$(date +%Y%m%d-%H%M%S)"
      sudo cp /etc/wsl.conf "$BACKUP"
      info "Backed up existing /etc/wsl.conf to $BACKUP"
    fi
    echo "$WSL_CONF_NEW" | sudo tee /etc/wsl.conf > /dev/null
    step_done "wsl-conf"
    info "${C_YELLOW}Run 'wsl --shutdown' from Windows PowerShell after this script finishes to pick up the new config.${C_RESET}"
  fi
else
  : # not WSL, skip silently
fi

echo "itc-bootstrap: WSL overlay handled — remaining steps land in subsequent commits"
exit 0
