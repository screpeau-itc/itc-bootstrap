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
options="ro"
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

# Fast path: if claude is installed AND already authed, skip the install +
# interactive auth pause entirely. Probe auth via `claude mcp list` which
# requires a valid token (in 2.1.x there's no `claude auth status` command).
if command -v claude >/dev/null 2>&1 && claude mcp list >/dev/null 2>&1; then
  step_skip "claude-cli" "claude $(claude --version) already installed and authenticated"
else
  # Install if missing
  if ! command -v claude >/dev/null 2>&1; then
    sudo npm install -g @anthropic-ai/claude-code
    if ! command -v claude >/dev/null 2>&1; then
      step_fail "claude-cli" "npm install completed but 'claude' is not on PATH"
      exit 1
    fi
    info "Installed: $(claude --version)"
  else
    info "claude already installed: $(claude --version) — but not yet authenticated"
  fi

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
fi

# ─── [gh] GitHub CLI + auth ────────────────────────────────────────────────────

step_start "gh" "Installing GitHub CLI and authenticating"

# Required scopes:
#   - repo, workflow, read:org: core needs (clone, actions, org membership)
#   - read:public_key: required by /user/keys in the [ssh-in] step
REQUIRED_SCOPES=("repo" "workflow" "read:org" "read:public_key")

# Predicate: gh is installed AND authed AND all required scopes are present.
gh_is_ready() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  local current_scopes scope
  current_scopes=$(gh auth status 2>&1 | grep -oE "'[a-z:_]+'" | tr -d "'" || true)
  for scope in "${REQUIRED_SCOPES[@]}"; do
    grep -qw "$scope" <<< "$current_scopes" || return 1
  done
  return 0
}

# Fast path: if gh is installed AND already authed with the required scopes,
# skip install + auth entirely.
if gh_is_ready; then
  step_skip "gh" "gh $(gh --version | head -1 | awk '{print $3}') already installed and authenticated with required scopes"
else
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

  # Report which scopes are missing (informational)
  if gh auth status >/dev/null 2>&1; then
    CURRENT_SCOPES=$(gh auth status 2>&1 | grep -oE "'[a-z:_]+'" | tr -d "'" || true)
    MISSING=()
    for scope in "${REQUIRED_SCOPES[@]}"; do
      grep -qw "$scope" <<< "$CURRENT_SCOPES" || MISSING+=("$scope")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
      info "gh auth missing scopes: ${MISSING[*]}; will refresh"
    fi
  fi

  echo
  info "${C_BOLD}GitHub authentication${C_RESET}"
  info "This will open a browser tab and ask you to paste a one-time code."
  info "Choose: GitHub.com / HTTPS / Login with browser."
  echo
  if gh auth status >/dev/null 2>&1; then
    # Already authed, just need scope refresh
    gh auth refresh --hostname github.com -s "repo,workflow,read:org,read:public_key"
  else
    gh auth login --scopes "repo,workflow,read:org,read:public_key" --hostname github.com --git-protocol https --web
  fi
  # Re-verify
  if ! gh auth status >/dev/null 2>&1; then
    step_fail "gh" "authentication did not complete"
    exit 1
  fi
  step_done "gh"
fi

# ─── [ssh-in] Inbound SSH ──────────────────────────────────────────────────────

if [[ "$INBOUND_SSH" == "y" ]]; then
  step_start "ssh-in" "Configuring inbound SSH"

  # Install + enable sshd.
  # On a fresh WSL distro the very first script run happens BEFORE 'wsl --shutdown'
  # has picked up `[boot] systemd=true`, so systemd isn't PID 1 yet. Fall back to
  # the legacy `service` command in that case; the systemctl-enable side effect
  # (auto-start at boot) takes over once systemd actually runs.
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    sudo apt-get install -y openssh-server
  fi
  if pidof systemd >/dev/null 2>&1; then
    sudo systemctl enable --now ssh
  else
    sudo systemctl enable ssh >/dev/null 2>&1 || true   # records the enable for next boot
    sudo service ssh start >/dev/null 2>&1 || true
    info "${C_YELLOW}systemd not yet running (pre-shutdown WSL session).${C_RESET}"
    info "${C_YELLOW}sshd started via legacy 'service'; it will auto-start at boot after 'wsl --shutdown'.${C_RESET}"
  fi

  # Prepare ~/.ssh
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"

  # Helper: real SSH key fingerprint (handles option-prefixed authorized_keys lines).
  # Returns empty on parse failure rather than crashing under set -e.
  ssh_fingerprint() {
    local key="$1"
    ssh-keygen -lf - <<<"$key" 2>/dev/null | awk '{print $2}'
  }

  # Helper: is this fingerprint already in authorized_keys?
  has_fingerprint() {
    local fp="$1"
    [[ -z "$fp" ]] && return 1
    [[ -s "$HOME/.ssh/authorized_keys" ]] || return 1
    ssh-keygen -lf "$HOME/.ssh/authorized_keys" 2>/dev/null \
      | awk '{print $2}' | grep -qFx "$fp"
  }

  # Fetch user's GitHub-registered pubkeys via the raw API endpoint.
  # We avoid `gh ssh-key list` because in recent gh versions it ALSO probes
  # /user/ssh_signing_keys (signing keys) which requires admin:ssh_signing_key
  # scope — its 404 makes gh exit non-zero, masking the auth-keys we DO have.
  # `gh api user/keys` is the focused single call (needs only read:public_key).
  KEYS_TMP=$(mktemp)
  KEYS_JSON="[]"
  if gh api user/keys > "$KEYS_TMP" 2>/dev/null; then
    KEYS_JSON=$(<"$KEYS_TMP")
  else
    info "${C_YELLOW}Warning:${C_RESET} 'gh api user/keys' failed."
    info "Possible causes: missing scope, expired token, network down."
    info "Run 'gh auth status' / 'gh auth refresh' and re-run this installer to add keys."
  fi
  rm -f "$KEYS_TMP"
  KEY_COUNT=$(jq 'length' <<<"$KEYS_JSON")

  if [[ "$KEY_COUNT" -eq 0 ]]; then
    info "${C_YELLOW}No SSH keys found on your GitHub account.${C_RESET}"
    info "Skipping authorized_keys setup. Use 'gh ssh-key add' to register a key later."
  else
    echo
    info "Your GitHub-registered SSH public keys:"
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.title) (id \(.value.id))"' <<<"$KEYS_JSON"
    echo
    prompt "Enter numbers to install (space-separated, or 'all', or empty to skip): "
    read -r PICKS < /dev/tty
    case "$PICKS" in
      all|ALL)
        SELECTED=$(jq -r '.[].key' <<<"$KEYS_JSON")
        ;;
      "")
        SELECTED=""
        ;;
      *)
        SELECTED=""
        for n in $PICKS; do
          # Guard non-numeric input — `1 2 foo` shouldn't abort under set -e
          [[ "$n" =~ ^[0-9]+$ ]] || { info "Skipping non-numeric input: '$n'"; continue; }
          IDX=$((n - 1))
          K=$(jq -r ".[$IDX].key // empty" <<<"$KEYS_JSON")
          if [[ -n "$K" ]]; then
            SELECTED+="$K"$'\n'
          fi
        done
        ;;
    esac

    if [[ -n "$SELECTED" ]]; then
      ADDED=0
      while IFS= read -r KEY; do
        [[ -z "$KEY" ]] && continue
        FP=$(ssh_fingerprint "$KEY")
        if has_fingerprint "$FP"; then
          info "Skipping (already present): ${KEY:0:40}..."
        else
          echo "$KEY" >> "$HOME/.ssh/authorized_keys"
          ADDED=$((ADDED + 1))
        fi
      done <<< "$SELECTED"
      info "Added $ADDED key(s) to ~/.ssh/authorized_keys"
    fi
  fi

  # Optional: add another GitHub user's pubkeys
  echo
  ask_yes_no "Add another GitHub user's public keys (e.g., for a teammate)?" "n" ADD_OTHER
  if [[ "$ADD_OTHER" == "y" ]]; then
    while true; do
      prompt "GitHub username (empty to stop): "
      read -r OTHER_USER < /dev/tty
      [[ -z "$OTHER_USER" ]] && break
      OTHER_KEYS=$(gh api "users/$OTHER_USER/keys" --jq '.[].key' 2>/dev/null || echo "")
      if [[ -z "$OTHER_KEYS" ]]; then
        info "No public keys found for '$OTHER_USER' (or user does not exist)."
      else
        # Subshell-around-while is fine here: only side effects are info echoes and
        # appends to authorized_keys; no variable needs to escape the subshell.
        echo "$OTHER_KEYS" | while IFS= read -r K; do
          FP=$(ssh_fingerprint "$K")
          if has_fingerprint "$FP"; then
            info "Skipping (already present): ${K:0:40}..."
          else
            echo "$K $OTHER_USER@github" >> "$HOME/.ssh/authorized_keys"
            info "Added: ${K:0:40}..."
          fi
        done
      fi
    done
  fi

  # Print reachable address. Use `ip route get` to find the primary-egress
  # interface's source IP — doesn't assume eth0 (which is WSL-specific;
  # Docker/LXC/VM/native often use enp0s3 / ens4 / etc.).
  IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
       | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}' \
       | head -1)
  if [[ -n "$IP" ]]; then
    echo
    info "SSH server is listening on $IP"
    if [[ "$ENV_TYPE" == "wsl" ]]; then
      info "${C_YELLOW}WSL caveat: this IP is reachable from your Windows host only.${C_RESET}"
      info "${C_YELLOW}It is ephemeral (rerolls on 'wsl --shutdown'). External access requires netsh portproxy (not recommended).${C_RESET}"
    fi
  fi

  step_done "ssh-in"
fi

# ─── [marketplace] Register marketplace + install itc-base ─────────────────────

step_start "marketplace" "Registering itc-claude-marketplace + installing itc-base"

# Add marketplace (idempotent: claude reports an error but doesn't break if already added)
if claude plugin marketplace list --json 2>/dev/null \
   | jq -e '.[] | select(.name == "itc-claude-marketplace")' >/dev/null; then
  info "Marketplace itc-claude-marketplace already registered"
else
  claude plugin marketplace add screpeau-itc/itc-claude-marketplace
fi

# Install itc-base
# NOTE: itc-base plugin does not yet exist in the marketplace as of this script being written;
# this install will fail until the layer-2 batch creates it. The installer treats that as a
# non-fatal warning at the final hand-off step rather than failing here.
if claude plugin list 2>/dev/null | grep -q "itc-base"; then
  info "Plugin itc-base already installed"
else
  if claude plugin install itc-base@itc-claude-marketplace 2>&1; then
    info "Installed plugin: itc-base"
  else
    info "${C_YELLOW}itc-base plugin install failed — likely the plugin does not yet exist in the marketplace.${C_RESET}"
    info "${C_YELLOW}This is expected during the layer-1-only phase. Continuing.${C_RESET}"
  fi
fi

step_done "marketplace"

# ─── [handoff] Hand off to Claude session ──────────────────────────────────────

step_start "handoff" "Handing off to Claude session"

echo
info "${C_GREEN}${C_BOLD}═══════════════════════════════════════════════════════${C_RESET}"
info "${C_GREEN}${C_BOLD}  itc-bootstrap layer-1 complete.${C_RESET}"
info "${C_GREEN}${C_BOLD}═══════════════════════════════════════════════════════${C_RESET}"
echo
info "Workspace: $WORKSPACE_DIR"
info "Marketplace: itc-claude-marketplace (registered)"
info "Plugin: itc-base (installed if available)"
echo

if [[ "$ENV_TYPE" == "wsl" ]]; then
  info "${C_YELLOW}WSL: run 'wsl --shutdown' from PowerShell to pick up /etc/wsl.conf changes.${C_RESET}"
  echo
fi

info "Launching Claude session in your workspace..."
sleep 2

cd "$WORKSPACE_DIR"
# Replace this shell with claude. Two stdin-related details matter here:
#   1) Redirect stdin to /dev/tty — under `curl ... | bash`, bash's stdin
#      is the script pipe. Without redirection claude would inherit it and
#      consume the post-exec lines of install.sh as input (observed in T18).
#   2) The trailing line of install.sh is this exec — nothing after — so
#      even if a future edit forgets (1), there's no bash code left to leak.
# Initial prompt as positional argument matches claude CLI 2.1.x convention.
exec claude "/itc-base-setup" < /dev/tty
