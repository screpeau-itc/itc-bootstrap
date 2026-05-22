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

# ─── [dev-dir] Workspace directory ─────────────────────────────────────────────

step_start "dev-dir" "Creating workspace directory"

mkdir -p "$WORKSPACE_DIR"
# Defensive: if for any reason ownership is wrong (e.g., script run partially as root in past), fix it
if [[ "$(stat -c '%U' "$WORKSPACE_DIR")" != "$USER" ]]; then
  sudo chown -R "$USER:$USER" "$HOME/dev" "$WORKSPACE_DIR"
fi

info "Workspace dir: $WORKSPACE_DIR"
step_done "dev-dir"

# ─── [claude-trust] Pre-stage Claude trust config ──────────────────────────────

step_start "claude-trust" "Pre-trusting workspace directory in Claude config"

CLAUDE_CONFIG="$HOME/.claude.json"

# If file doesn't exist, create it with just our trust entry
if [[ ! -f "$CLAUDE_CONFIG" ]]; then
  cat > "$CLAUDE_CONFIG" <<EOF
{
  "projects": {
    "$WORKSPACE_DIR": {
      "hasTrustDialogAccepted": true
    }
  }
}
EOF
  chmod 600 "$CLAUDE_CONFIG"
  step_done "claude-trust"
else
  # File exists — merge using jq (jq is in our base packages, installed in Task 5)
  TMP=$(mktemp)
  jq --arg path "$WORKSPACE_DIR" \
     '.projects[$path] = ((.projects[$path] // {}) + {"hasTrustDialogAccepted": true})' \
     "$CLAUDE_CONFIG" > "$TMP"
  # Verify the merge produced valid JSON
  if jq -e . "$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$CLAUDE_CONFIG"
    chmod 600 "$CLAUDE_CONFIG"
    step_done "claude-trust"
  else
    rm -f "$TMP"
    step_fail "claude-trust" "merged config is invalid JSON; original ~/.claude.json untouched"
    exit 1
  fi
fi

# ─── [node] Node LTS ───────────────────────────────────────────────────────────

step_start "node" "Installing Node.js LTS"

NEEDED_NODE_MAJOR=20  # Current LTS major as of 2026-05; bump if NodeSource defaults change

if command -v node >/dev/null 2>&1; then
  CURRENT_MAJOR=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo "0")
  if [[ "$CURRENT_MAJOR" -ge "$NEEDED_NODE_MAJOR" ]]; then
    step_skip "node" "node $(node --version) already installed (>= v${NEEDED_NODE_MAJOR})"
  else
    info "Node v${CURRENT_MAJOR} installed but older than required v${NEEDED_NODE_MAJOR}; upgrading"
    curl -fsSL "https://deb.nodesource.com/setup_lts.x" | sudo -E bash -
    sudo apt-get install -y nodejs
    step_done "node"
  fi
else
  curl -fsSL "https://deb.nodesource.com/setup_lts.x" | sudo -E bash -
  sudo apt-get install -y nodejs
  step_done "node"
fi

info "Node: $(node --version), npm: $(npm --version)"

# ─── [claude-cli] Claude Code CLI ──────────────────────────────────────────────

step_start "claude-cli" "Installing Claude Code CLI"

if command -v claude >/dev/null 2>&1; then
  info "claude already installed: $(claude --version)"
else
  sudo npm install -g @anthropic-ai/claude-code
  if ! command -v claude >/dev/null 2>&1; then
    step_fail "claude-cli" "npm install completed but 'claude' is not on PATH"
    exit 1
  fi
  info "Installed: $(claude --version)"
fi

# Check auth status. claude provides no `claude auth status` command in 2.1.x,
# so probe by running a no-op interactive command and inspecting output.
# Simpler: just always pause for the user to confirm.
echo
info "${C_BOLD}Claude Code first-run authentication${C_RESET}"
info "If not already authenticated, run this in another terminal NOW:"
info "  ${C_BLUE}claude${C_RESET}    (it will open a browser tab for Anthropic login)"
info "Once you see the welcome prompt in that other terminal, return here."
echo

AUTH_TRIES=0
while [[ $AUTH_TRIES -lt 3 ]]; do
  AUTH_TRIES=$((AUTH_TRIES + 1))
  ask_yes_no "Have you completed Claude Code authentication?" "y" CONFIRM
  if [[ "$CONFIRM" == "y" ]]; then
    # Probe by attempting a no-op that requires auth: list MCPs
    if claude mcp list >/dev/null 2>&1; then
      step_done "claude-cli"
      break
    else
      info "${C_YELLOW}Claude CLI is not responding as authenticated. Try running 'claude' again to complete login.${C_RESET}"
    fi
  fi
  if [[ $AUTH_TRIES -ge 3 ]]; then
    step_fail "claude-cli" "auth not detected after 3 attempts"
    info "Run 'claude' manually to complete auth, then re-run this installer to resume."
    exit 1
  fi
done

# ─── [gh] GitHub CLI + auth ────────────────────────────────────────────────────

step_start "gh" "Installing GitHub CLI and authenticating"

# Install gh from official apt repo if not present
if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y gh
  info "Installed: $(gh --version | head -1)"
else
  info "gh already installed: $(gh --version | head -1)"
fi

# Check existing auth + scopes
REQUIRED_SCOPES=("repo" "workflow" "read:org")
AUTH_OK="n"

if gh auth status >/dev/null 2>&1; then
  CURRENT_SCOPES=$(gh auth status 2>&1 | grep -oE "'[a-z:]+'" | tr -d "'" || true)
  MISSING=()
  for scope in "${REQUIRED_SCOPES[@]}"; do
    if ! grep -qw "$scope" <<< "$CURRENT_SCOPES"; then
      MISSING+=("$scope")
    fi
  done
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    AUTH_OK="y"
    info "gh already authenticated with required scopes"
  else
    info "gh auth missing scopes: ${MISSING[*]}; will refresh"
  fi
fi

if [[ "$AUTH_OK" == "n" ]]; then
  echo
  info "${C_BOLD}GitHub authentication${C_RESET}"
  info "This will open a browser tab and ask you to paste a one-time code."
  info "Choose: GitHub.com / HTTPS / Login with browser."
  echo
  if gh auth status >/dev/null 2>&1; then
    # Already authed, just need scope refresh
    gh auth refresh -s "repo,workflow,read:org"
  else
    gh auth login --scopes "repo,workflow,read:org" --hostname github.com --git-protocol https --web
  fi
  # Re-verify
  if ! gh auth status >/dev/null 2>&1; then
    step_fail "gh" "authentication did not complete"
    exit 1
  fi
fi

step_done "gh"

echo "itc-bootstrap: gh installed and authed — remaining steps in subsequent commits"
exit 0
