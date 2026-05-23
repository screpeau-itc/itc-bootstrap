#!/usr/bin/env bash
# itc-bootstrap — cold-start installer for Claude Code on Ubuntu/WSL
# See README.md for usage. Designed to be invoked via:
#   curl -fsSL "https://raw.githubusercontent.com/screpeau-itc/itc-bootstrap/main/install.sh?v=$(date +%s)" | bash
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

# Phase-2-pending guard: refuse to proceed if phase 1 already finished but
# phase 2 hasn't run yet. Without this, a manual install.sh re-run before
# `wsl --shutdown` would defeat the phase-split design (handoff would land
# in a still-stale shell, missing systemd / docker-group / PATH activations).
#
# The Y path of resume.sh removes resume.sh BEFORE re-curling install.sh,
# so phase 2 (auto-resume) passes this guard cleanly.
if [[ -f "$HOME/.local/share/itc-bootstrap/resume.sh" ]]; then
  info "Phase 1 has already completed; phase 2 is pending."
  info "Restart WSL to finish setup:"
  info "  1) exit"
  info "  2) From PowerShell:  wsl --shutdown ; wsl -d Ubuntu"
  info "     (use ';' not '&&' — Windows PowerShell 5.1 doesn't support '&&'."
  info "     '-d Ubuntu' explicitly picks the distro in case 'wsl' alone falls back to a system distro.)"
  info "(Your next bash login will prompt to finish.)"
  echo
  info "Or to discard the pending phase 2 and run the installer fresh:"
  info "  rm $HOME/.local/share/itc-bootstrap/resume.sh"
  exit 0
fi

# Ensure ~/.local/bin is on PATH for the duration of this script. We're invoked
# via `curl ... | bash`, which is non-interactive — bash skips ~/.bashrc, so
# even though the claude native installer added the export there, this shell
# doesn't see it. Without this prepend, fast-path checks like
# `command -v claude` fail when claude is already at ~/.local/bin/claude,
# causing the installer to redundantly re-run on every invocation.
export PATH="$HOME/.local/bin:$PATH"

# ─── Auto-logging (v0.4.6) ─────────────────────────────────────────────────────
# Capture all script output to a timestamped log file under
# ~/.local/share/itc-bootstrap/logs/. Helps debug install issues without the
# operator having to remember `tee` redirects. Both phase 1 and phase 2 (auto-
# resume) get their own log files. Log path is printed at start and end of run.

ITC_LOG_DIR="$HOME/.local/share/itc-bootstrap/logs"
mkdir -p "$ITC_LOG_DIR"
ITC_LOG_FILE="$ITC_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"

# Seed the log with run metadata before we redirect.
{
  echo "=== itc-bootstrap install log ==="
  echo "Started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "User:     $USER"
  echo "Hostname: $(hostname)"
  echo "Pwd:      $(pwd)"
  echo "Bash:     $BASH_VERSION"
  echo "Phase 2:  ${ITC_BOOTSTRAP_AUTO_RESUME:-no}"
  echo "==="
  echo ""
} > "$ITC_LOG_FILE"

# Redirect stdout+stderr through tee so output goes to BOTH the terminal and
# the log file. Process substitution runs tee in a subshell; bash forks it and
# the main script's fds 1 and 2 point at tee's stdin from here on.
exec > >(tee -a "$ITC_LOG_FILE") 2>&1

# Trap EXIT so the operator sees the log path one last time when the script
# ends — useful when a silent crash, manual interrupt, or exec-to-claude
# happens and they want to see what was captured.
_itc_print_log_path() {
  printf '\n%sLog file (this run):%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$ITC_LOG_FILE" >/dev/tty 2>/dev/null || \
    printf '\nLog file (this run): %s\n' "$ITC_LOG_FILE"
}
trap _itc_print_log_path EXIT

# Announce log location at the top so it's visible early.
printf '%sLog file:%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$ITC_LOG_FILE"
info "(All output of this run is captured. Share this log if anything breaks.)"
echo

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

# Phase-1-end helper (used by the [phase-1-end] branch in Task 5).
# Writes resume.sh into ~/.local/share/itc-bootstrap and appends a guarded
# snippet to ~/.bashrc that sources it on next interactive login.
# Idempotent: re-writes resume.sh unconditionally (so updates ship); appends
# the bashrc snippet only if its start-marker isn't already present.
install_resume_artifacts() {
  local resume_dir="$HOME/.local/share/itc-bootstrap"
  local resume_path="$resume_dir/resume.sh"
  local bashrc="$HOME/.bashrc"
  local start_marker="# >>> itc-bootstrap auto-resume >>>"
  local end_marker="# <<< itc-bootstrap auto-resume <<<"

  mkdir -p "$resume_dir"

  # Single-quoted heredoc: $vars in the body stay literal, expanded at
  # source-time inside the user's interactive shell — not now.
  cat > "$resume_path" <<'RESUME_EOF'
#!/usr/bin/env bash
# itc-bootstrap auto-resume — sourced by ~/.bashrc after phase 1.
# Prompts user to run phase 2; self-deletes (and removes bashrc hook) on Y or never.

# Defense: only prompt on interactive shells with a real tty.
if [[ $- != *i* ]] || [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

_itc_resume_self="$HOME/.local/share/itc-bootstrap/resume.sh"
_itc_bashrc="$HOME/.bashrc"

_itc_cleanup() {
  rm -f "$_itc_resume_self"
  if [[ -f "$_itc_bashrc" ]]; then
    sed -i '/^# >>> itc-bootstrap auto-resume >>>$/,/^# <<< itc-bootstrap auto-resume <<<$/d' "$_itc_bashrc"
  fi
}

printf '\n\033[1mitc-bootstrap:\033[0m phase 1 complete. Run phase 2 (claude handoff) now? \033[33m[Y/n/never]\033[0m '
read -r _itc_reply < /dev/tty
case "${_itc_reply,,}" in
  ""|y|yes)
    _itc_cleanup
    printf 'Running phase 2...\n\n'
    # Env-var prefix must be on `bash` (the pipeline's right-hand command that
    # executes install.sh), NOT on `curl` (which doesn't read it). Without this,
    # install.sh runs without ITC_BOOTSTRAP_AUTO_RESUME=1 and re-asks the prompts.
    curl -fsSL "https://raw.githubusercontent.com/screpeau-itc/itc-bootstrap/main/install.sh?v=$(date +%s)" | ITC_BOOTSTRAP_AUTO_RESUME=1 bash
    ;;
  never)
    _itc_cleanup
    printf 'OK, dismissed. To finish later, re-run the install.sh curl one-liner.\n'
    ;;
  *)
    printf 'OK, will ask again next login. Answer "never" to dismiss permanently.\n'
    ;;
esac

unset _itc_reply _itc_resume_self _itc_bashrc
unset -f _itc_cleanup
RESUME_EOF
  chmod 644 "$resume_path"

  # Append bashrc snippet only if start-marker isn't already there.
  # `touch` defends against the (rare) case of a missing ~/.bashrc.
  touch "$bashrc"
  if ! grep -Fq "$start_marker" "$bashrc"; then
    cat >> "$bashrc" <<EOF
$start_marker
[[ -f "\$HOME/.local/share/itc-bootstrap/resume.sh" ]] && source "\$HOME/.local/share/itc-bootstrap/resume.sh"
$end_marker
EOF
  fi
}

# Helper: appends a guarded "auto-cd to ~/dev (or \$HOME)" snippet to ~/.bashrc.
# Solves the WSL paper-cut where launching from a PowerShell prompt at e.g.
# C:\windows\system32 lands you in /mnt/c/windows/system32 because WSL
# inherits the launcher's CWD. We snap to ~/dev (or \$HOME if that doesn't
# exist) on interactive shells whose CWD looks Windows-inherited.
# Idempotent: skips if our start-marker is already present.
install_auto_cd_to_home() {
  local bashrc="$HOME/.bashrc"
  local start_marker="# >>> itc-bootstrap auto-cd >>>"
  local end_marker="# <<< itc-bootstrap auto-cd <<<"

  touch "$bashrc"
  if ! grep -Fq "$start_marker" "$bashrc"; then
    cat >> "$bashrc" <<EOF
$start_marker
# Auto-cd to ~/dev (or \$HOME) when WSL launches with a Windows-inherited
# /mnt/* CWD. Interactive shells only — scripts that explicitly cd into
# a /mnt path are unaffected.
if [[ \$- == *i* ]] && [[ "\$PWD" == /mnt/* ]]; then
  if [[ -d "\$HOME/dev" ]]; then
    cd "\$HOME/dev"
  else
    cd "\$HOME"
  fi
fi
$end_marker
EOF
  fi
}

echo
info "${C_BOLD}A few quick questions, then the installer runs uninterrupted until it needs interactive auth.${C_RESET}"
echo

# Tracking flags for the phase-split decision in Task 5. Both default to 'n';
# the [wsl-conf] and [docker] steps will flip them to 'y' if they actually
# write/install (vs. fast-path skip).
WSL_CONF_WAS_WRITTEN=n
DOCKER_WAS_INSTALLED=n

# Preference persistence file. Loaded before prompts (as defaults), saved
# after prompts validate. XDG-compliant location.
_ITC_PREFS="$HOME/.config/itc-bootstrap/preferences.env"

# Load remembered preferences from previous run, if present. Safe because we
# wrote the file ourselves with simple KEY=value lines.
if [[ -f "$_ITC_PREFS" ]]; then
  # shellcheck disable=SC1090
  source "$_ITC_PREFS"
fi

# v0.4.7: detect existing passwordless sudo BEFORE prompts. If NOPASSWD: ALL
# is already in the operator's sudo policy (from a prior install run or other
# config), skip the passwordless-sudo prompt entirely on this run — no point
# asking when it's already active.
#
# sudo -n -l: non-interactive list of sudo privileges. Succeeds if NOPASSWD or
# cached creds; output includes 'NOPASSWD: ALL' iff the operator has
# unconditional passwordless sudo. Grep for that exact pattern (defensive — a
# partial 'NOPASSWD: /usr/bin/foo' entry would NOT match).
PWLESS_ALREADY_ACTIVE=n
if sudo -n -l 2>/dev/null | grep -qE 'NOPASSWD.*ALL'; then
  PWLESS_ALREADY_ACTIVE=y
fi

# Auto-resume path (phase 2 from resume.sh): skip prompts, use what phase 1 saved.
# The ITC_BOOTSTRAP_AUTO_RESUME=1 env var is set ONLY by resume.sh's Y branch.
if [[ "${ITC_BOOTSTRAP_AUTO_RESUME:-}" == "1" && -f "$_ITC_PREFS" ]]; then
  info "${C_GREEN}▶ Phase 2: resuming with remembered preferences (no prompts).${C_RESET}"
  # Defensive fallbacks in case prefs file is partial
  : "${INBOUND_SSH:=$DEFAULT_INBOUND_SSH}"
  : "${WANT_DOCKER:=y}"
  : "${WANT_PASSWORDLESS_SUDO:=n}"
else
  ask_yes_no       "Enable inbound SSH on this host (so you can SSH in from another machine)?" \
                   "${INBOUND_SSH:-$DEFAULT_INBOUND_SSH}" INBOUND_SSH

  # v0.4.3: gate the Docker prompt by environment.
  #   docker: installing Docker inside Docker is special-cased (DinD) and not
  #           appropriate for an end-user dev environment.
  #   lxc:    unprivileged containers can't run Docker; privileged need host config.
  # For both, skip the prompt entirely and force WANT_DOCKER=n.
  case "$ENV_TYPE" in
    docker|lxc)
      WANT_DOCKER=n
      info "Container environment ($ENV_TYPE) detected — skipping Docker prompt (Docker setup is N/A here)."
      ;;
    *)
      ask_yes_no   "Install Docker (docker-ce + compose plugin)?" "${WANT_DOCKER:-y}" WANT_DOCKER
      ;;
  esac

  # v0.4.7: only ask about passwordless sudo if it's NOT already active.
  if [[ "$PWLESS_ALREADY_ACTIVE" == "y" ]]; then
    WANT_PASSWORDLESS_SUDO=y
    info "Passwordless sudo already active for $USER — skipping prompt."
  else
    ask_yes_no     "Set up passwordless sudo for $USER (recommended for unattended install)?" \
                   "${WANT_PASSWORDLESS_SUDO:-y}" WANT_PASSWORDLESS_SUDO
  fi
fi

# v0.4.0: admin workspace dir is now fixed. /itc-base-setup (itc-base plugin)
# turns this into a "system admin workspace"; project work happens in
# separate dirs created by future /itc-workspace-new (itc-base v0.2.0+).
WORKSPACE_DIR="$HOME/dev/itx-claude-admin"

# Persist preferences IMMEDIATELY (before any install work runs). If the user
# Ctrl-C's mid-install, their answers survive for the next attempt.
mkdir -p "$(dirname "$_ITC_PREFS")"
cat > "$_ITC_PREFS" <<EOF
# itc-bootstrap remembered preferences — used as defaults on next run.
# Safe to delete; will be regenerated.
INBOUND_SSH=$INBOUND_SSH
WANT_DOCKER=$WANT_DOCKER
WANT_PASSWORDLESS_SUDO=$WANT_PASSWORDLESS_SUDO
EOF
chmod 600 "$_ITC_PREFS"

# v0.4.2: passwordless sudo setup BEFORE any sudo command runs in the install,
# so subsequent sudos don't prompt. Operator is asked once for their password
# (sudo -v) and the sudoers.d entry is written. Idempotent — re-running on a
# machine that already has the entry is a no-op.
#
# v0.4.9: the "already configured?" probe must check the actual sudoers policy
# (NOPASSWD: ALL via `sudo -n -l`), NOT `sudo -n true`. The latter passes if
# sudo credentials are merely *cached* in the timestamp (e.g., operator just
# ran `sudo apt install curl` before `curl | bash`), giving a false positive
# that skips writing the sudoers.d file in phase 1 — and then phase 2 catches
# the missing policy, configures it for real, and prompts for the password.
# Same NOPASSWD check used at PWLESS_ALREADY_ACTIVE earlier.
if [[ "$WANT_PASSWORDLESS_SUDO" == "y" ]]; then
  PWLESS_FILE="/etc/sudoers.d/itc-bootstrap-$USER"
  if sudo -n -l 2>/dev/null | grep -qE 'NOPASSWD.*ALL'; then
    info "Passwordless sudo already active for $USER — skipping setup."
  else
    info "Configuring passwordless sudo for $USER (you will be prompted for your password ONCE)..."
    sudo -v
    echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "$PWLESS_FILE" > /dev/null
    sudo chmod 0440 "$PWLESS_FILE"
    info "Passwordless sudo configured. Remove with: sudo rm $PWLESS_FILE"
  fi
fi

echo
info "Will use workspace:  $WORKSPACE_DIR"
info "Inbound SSH:         $([[ "$INBOUND_SSH" == "y" ]] && echo "enabled" || echo "disabled")"
info "Docker:              $([[ "$WANT_DOCKER" == "y" ]] && echo "install"  || echo "skip")"
info "Passwordless sudo:   $([[ "$WANT_PASSWORDLESS_SUDO" == "y" ]] && echo "configured" || echo "not configured (will prompt as needed)")"
echo

# ─── [base-pkgs] Base packages ─────────────────────────────────────────────────

step_start "base-pkgs" "Installing base packages"

BASE_PACKAGES=(
  build-essential git ca-certificates gnupg lsb-release jq tmux unzip
  python3-pip python3-venv pipx
  # util-linux-extra provides `newgrp`, used after the docker-group add so the
  # user can pick up new group membership without logging out.
  util-linux-extra
)

# Update apt index (quietly, but show errors)
sudo apt-get update -qq

# Install all in one apt invocation (handles already-installed automatically)
sudo apt-get install -y "${BASE_PACKAGES[@]}"

step_done "base-pkgs"

# ─── [wsl-conf] WSL overlay ────────────────────────────────────────────────────

if [[ "$ENV_TYPE" == "wsl" ]]; then
  step_start "wsl-conf" "Writing /etc/wsl.conf"

  # v0.4.1: use the current UNIX user, not a hardcoded name. ${USER} is set by
  # the login shell; fall back to whoami if it isn't (e.g., in some non-interactive
  # contexts). Note unquoted EOF so the variable expands.
  WSL_DEFAULT_USER="${USER:-$(whoami)}"
  WSL_CONF_NEW=$(cat <<EOF
[boot]
systemd=true

[user]
default=${WSL_DEFAULT_USER}

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
    WSL_CONF_WAS_WRITTEN=y
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

# ─── [claude-trust] Pre-stage Claude trust + onboarding skip ──────────────────

step_start "claude-trust" "Pre-trusting workspace dir + suppressing claude first-run prompts"

CLAUDE_CONFIG="$HOME/.claude.json"

# v0.4.4: in addition to trusting the workspace dir, pre-stage claude's
# onboarding-completion flags so the operator doesn't see the theme picker,
# welcome screen, or marketplace auto-install prompt on first launch. The
# handoff exec passes the slash command immediately, so onboarding prompts
# would intercept and cause "Unknown command" errors.
#
# Keys set:
#   hasCompletedOnboarding=true + lastOnboardingVersion=<claude version>
#     → suppresses theme picker and welcome flow
#   officialMarketplaceAutoInstallAttempted=true + officialMarketplaceAutoInstalled=true
#     → suppresses claude's auto-marketplace prompt (itc-base's stage-1 installs
#       plugins explicitly, so claude's auto-install doesn't need to fire)
#
# v0.4.5: capture claude version for lastOnboardingVersion if available, but
# DO NOT call claude --version unconditionally — [claude-trust] runs at line
# 443 and the [claude-cli] install step doesn't run until line 538. Calling
# a not-yet-installed binary in a pipe under `set -euo pipefail` causes the
# script to exit silently (pipefail catches the 127, errexit ends the script
# without printing the failing step name).
#
# Use a high fallback version so claude treats this machine as "already
# onboarded to all known versions" until the operator opens claude for real.
CLAUDE_VERSION="99.99.99"
if command -v claude >/dev/null 2>&1; then
  # claude is on PATH (re-run case, not first install) — use real version
  DETECTED=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  [[ -n "$DETECTED" ]] && CLAUDE_VERSION="$DETECTED"
fi

# If file doesn't exist, create it with our trust entry + onboarding skip flags
if [[ ! -f "$CLAUDE_CONFIG" ]]; then
  cat > "$CLAUDE_CONFIG" <<EOF
{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "$CLAUDE_VERSION",
  "officialMarketplaceAutoInstallAttempted": true,
  "officialMarketplaceAutoInstalled": true,
  "projects": {
    "$WORKSPACE_DIR": {
      "hasTrustDialogAccepted": true
    }
  }
}
EOF
  chmod 600 "$CLAUDE_CONFIG"
else
  # File exists — merge using jq. Sets onboarding flags only if not already set
  # (// operator preserves operator-customized values).
  TMP=$(mktemp)
  jq --arg path "$WORKSPACE_DIR" --arg ver "$CLAUDE_VERSION" \
     '.projects[$path] = ((.projects[$path] // {}) + {"hasTrustDialogAccepted": true})
      | .hasCompletedOnboarding = (.hasCompletedOnboarding // true)
      | .lastOnboardingVersion = (.lastOnboardingVersion // $ver)
      | .officialMarketplaceAutoInstallAttempted = (.officialMarketplaceAutoInstallAttempted // true)
      | .officialMarketplaceAutoInstalled = (.officialMarketplaceAutoInstalled // true)' \
     "$CLAUDE_CONFIG" > "$TMP"
  # Verify the merge produced valid JSON
  if jq -e . "$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$CLAUDE_CONFIG"
    chmod 600 "$CLAUDE_CONFIG"
  else
    rm -f "$TMP"
    step_fail "claude-trust" "merged config is invalid JSON; original ~/.claude.json untouched"
    exit 1
  fi
fi

# v0.4.9: also pre-stage ~/.claude/settings.json with a permissions.allow rule
# for the wizard's stage-1 script. The /itc-base:itc-base-setup slash command
# body invokes `bash itc-base-stage1.sh`, which triggers claude's permission
# gate (even when permissions.defaultMode is bypassPermissions — that mode
# doesn't suppress bash invocations from slash-command bodies on a cold first
# launch). Pre-allowing it makes the wizard fully hands-off.
CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_SETTINGS_DIR/settings.json"
STAGE1_RULE='Bash(bash itc-base-stage1.sh:*)'

mkdir -p "$CLAUDE_SETTINGS_DIR"
if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
  cat > "$CLAUDE_SETTINGS" <<EOF
{
  "permissions": {
    "allow": ["$STAGE1_RULE"]
  }
}
EOF
  chmod 600 "$CLAUDE_SETTINGS"
else
  TMP=$(mktemp)
  jq --arg rule "$STAGE1_RULE" \
     '.permissions = (.permissions // {})
      | .permissions.allow = ((.permissions.allow // []) + [$rule] | unique)' \
     "$CLAUDE_SETTINGS" > "$TMP"
  if jq -e . "$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$CLAUDE_SETTINGS"
    chmod 600 "$CLAUDE_SETTINGS"
  else
    rm -f "$TMP"
    step_fail "claude-trust" "merged settings.json is invalid JSON; original untouched"
    exit 1
  fi
fi

step_done "claude-trust"

# ─── [shell-comfort] Sensible bashrc defaults ─────────────────────────────────

step_start "shell-comfort" "Adding shell-comfort defaults to ~/.bashrc"
install_auto_cd_to_home
step_done "shell-comfort"

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

# v0.4.8: probe auth via `claude auth status --json | jq -e .loggedIn`. The
# previous check used `claude mcp list`, which succeeded WITHOUT auth (it
# only reads local settings.json, never contacts Anthropic). That made the
# fast path falsely report "authenticated" on fresh installs, skipping the
# interactive auth prompt — operator landed at the [handoff] exec with an
# unauthenticated claude that immediately printed "Not logged in".
#
# `claude auth status --json` returns {"loggedIn": true|false, ...} and
# exits 0 in both cases (success means the command ran, not that auth was
# OK), so we MUST grep/jq the JSON rather than rely on exit code.
#
# Claude at any other path (e.g. /usr/bin from an old `sudo npm install -g`)
# drops into the install branch so we can replace it with the native installer.
if [[ "$(command -v claude 2>/dev/null)" == "$HOME/.local/bin/claude" ]] \
   && claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
  step_skip "claude-cli" "claude $(claude --version) already installed and authenticated"
else
  # Install or migrate to Anthropic's official native installer (NOT npm).
  # Per Anthropic docs: do NOT use `sudo npm install -g` — it leaves the global
  # modules dir root-owned and breaks claude's auto-update mechanism (the user
  # sees "Auto-update failed · Try claude doctor or npm i -g …" on every run).
  # The native installer drops claude in ~/.local/bin (user-owned) and
  # self-updates work out of the box.
  install_claude_native() {
    curl -fsSL https://claude.ai/install.sh | bash
    # The native installer adds ~/.local/bin to PATH via a shell-rc edit, but
    # the current shell needs an explicit prepend to find the new binary.
    export PATH="$HOME/.local/bin:$PATH"
    hash -r
    if [[ ! -x "$HOME/.local/bin/claude" ]]; then
      step_fail "claude-cli" "native installer completed but '\$HOME/.local/bin/claude' is missing or not executable"
      exit 1
    fi
  }

  if ! command -v claude >/dev/null 2>&1; then
    # Fresh install
    install_claude_native
    info "Installed: $(claude --version)"
  elif [[ "$(command -v claude)" != "$HOME/.local/bin/claude" ]]; then
    # Wrong location (old `sudo npm install -g`) — migrate to native.
    # Auth tokens live in ~/.claude.json (user-owned), so they survive this swap.
    CLAUDE_PATH=$(command -v claude)
    info "${C_YELLOW}claude is at $CLAUDE_PATH (not \$HOME/.local/bin/claude).${C_RESET}"
    info "${C_YELLOW}This is usually an old 'sudo npm install -g' which breaks auto-update.${C_RESET}"
    info "Removing the old install and re-installing via the native installer."
    sudo npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    install_claude_native
    info "Re-installed via native installer: $(claude --version)"
  fi

  # Whether we just installed or migrated, check auth before prompting.
  # Auth state is preserved across the migration (~/.claude.json untouched).
  # v0.4.8: use `claude auth status` (real auth probe), not `claude mcp list`
  # (local-only, doesn't verify auth).
  if claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
    step_done "claude-cli"
  else
    echo
    info "${C_BOLD}Claude Code first-run authentication${C_RESET}"
    info "About to launch ${C_BLUE}claude${C_RESET} inline — a browser tab will open for Anthropic OAuth."
    info "After signing in and seeing claude's welcome prompt, type ${C_BOLD}/exit${C_RESET} (or Ctrl-D)"
    info "to return here and continue the install."
    echo
    sleep 2

    # v0.4.9: run claude inline rather than telling the operator to open a
    # second terminal. /dev/tty stdin keeps the OAuth flow interactive even
    # though the script itself is in a `curl | bash` pipeline. /exit returns
    # nonzero — ignore it so the script continues to the auth-check below.
    claude < /dev/tty || true
    echo

    if claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
      step_done "claude-cli"
    else
      step_fail "claude-cli" "auth not detected after inline login attempt"
      info "Run 'claude' manually to complete auth, then re-run this installer to resume."
      exit 1
    fi
  fi
fi

# ─── [gh] GitHub CLI + auth ────────────────────────────────────────────────────

step_start "gh" "Installing GitHub CLI and authenticating"

# Required scopes:
#   - repo, workflow, read:org: core needs (clone, actions, org membership)
#   - read:public_key: required by /user/keys in the [ssh-in] step
REQUIRED_SCOPES=("repo" "workflow" "read:org" "read:public_key")

# Helper: list current token scopes, one per line.
# Reads X-Oauth-Scopes from an authenticated API response — robust to any
# future format drift in `gh auth status` human output (which has caught us
# twice now: scopes with ':' and scopes with '_').
gh_current_scopes() {
  gh api -i /user 2>/dev/null \
    | tr -d '\r' \
    | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' || true
}

# Predicate: gh is installed AND authed AND all required scopes are present.
gh_is_ready() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  local current_scopes scope
  current_scopes=$(gh_current_scopes)
  [[ -n "$current_scopes" ]] || return 1
  for scope in "${REQUIRED_SCOPES[@]}"; do
    grep -Fxq "$scope" <<< "$current_scopes" || return 1
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
    CURRENT_SCOPES=$(gh_current_scopes)
    MISSING=()
    for scope in "${REQUIRED_SCOPES[@]}"; do
      grep -Fxq "$scope" <<< "$CURRENT_SCOPES" || MISSING+=("$scope")
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

# ─── [docker] Docker (optional) ────────────────────────────────────────────────

if [[ "$WANT_DOCKER" == "y" ]]; then
  step_start "docker" "Installing Docker (docker-ce + compose plugin)"

  if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
    info "docker already installed: $(docker --version)"
  else
    # Install via Docker's official apt repo (NOT Ubuntu's docker.io, which lags
    # the upstream and omits the compose plugin we want).
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    UBUNTU_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
    if [[ -z "$UBUNTU_CODENAME" ]]; then
      step_fail "docker" "could not determine Ubuntu codename from /etc/os-release"
      exit 1
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    info "Installed: $(docker --version)"
    DOCKER_WAS_INSTALLED=y
  fi

  # Add current user to docker group (idempotent — usermod -a is a no-op if already a member).
  if id -nG "$USER" | tr ' ' '\n' | grep -Fxq docker; then
    info "User $USER already in docker group"
  else
    sudo usermod -aG docker "$USER"
    info "${C_YELLOW}Added $USER to docker group. Run 'newgrp docker' (or log out + back in) to use docker without sudo.${C_RESET}"
  fi

  # Enable + start the service. On a fresh WSL distro where /etc/wsl.conf was
  # written THIS run, systemd is not yet active (no /run/systemd/system) — the
  # service will start automatically after the user runs 'wsl --shutdown'.
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl enable --now docker
    info "Docker service enabled and started."
  else
    sudo systemctl enable docker 2>/dev/null || true
    info "${C_YELLOW}systemd not yet active (this is normal on a freshly-configured WSL distro).${C_RESET}"
    info "${C_YELLOW}Run 'wsl --shutdown' from PowerShell to apply /etc/wsl.conf; Docker will auto-start next boot.${C_RESET}"
  fi

  step_done "docker"
fi

# ─── [phase-1-end] Phase 1 / Phase 2 split point ──────────────────────────────
#
# If this run made changes that need a shell or WSL restart, pause here.
# Install the auto-resume hook, print restart instructions, and exit cleanly.
# The [marketplace] + [handoff] steps will run on the re-curl after restart
# (bashrc hook → resume.sh → Y → curl install.sh with ITC_BOOTSTRAP_AUTO_RESUME=1).
#
# Re-runs on already-bootstrapped distros (where wsl.conf already matches and
# docker was already installed) flow straight past this with both flags 'n'.

if [[ "$WSL_CONF_WAS_WRITTEN" == "y" || "$DOCKER_WAS_INSTALLED" == "y" ]]; then
  step_start "phase-1-end" "Phase 1 complete — installing auto-resume hook"
  install_resume_artifacts
  step_done "phase-1-end"
  echo
  info "${C_GREEN}═══════════════════════════════════════════════════════${C_RESET}"
  info "${C_GREEN}  Phase 1 done. Restart WSL to finish setup:${C_RESET}"
  info "${C_GREEN}═══════════════════════════════════════════════════════${C_RESET}"
  info "  1) exit"
  info "  2) From PowerShell:  wsl --shutdown ; wsl -d Ubuntu"
  info "     (use ';' not '&&' — Windows PowerShell 5.1 doesn't support '&&'."
  info "     '-d Ubuntu' explicitly picks the distro in case 'wsl' alone falls back to a system distro.)"
  info "Your next bash login will prompt to run phase 2 (claude handoff)."
  echo
  info "If for any reason the prompt doesn't fire (non-bash shell, etc.),"
  info "run the install.sh curl one-liner manually after restart."
  exit 0
fi

# ─── [marketplace] Register marketplace + install itc-base ─────────────────────

step_start "marketplace" "Registering itc-claude-marketplace + installing itc-base"

# Configure git's credential helper to use gh's token for HTTPS GitHub
# operations. Required for the HTTPS clone below: even public repos now
# refuse unauthenticated HTTPS clones (GitHub asks for username; with
# terminal prompts disabled in a piped-bash context, the clone bails).
# `gh auth setup-git` is idempotent — safe to re-run on already-configured
# systems. Errors are non-fatal because gh might not yet be authed in
# unusual states.
gh auth setup-git --hostname github.com 2>/dev/null || true

# Add marketplace (idempotent: claude reports an error but doesn't break if already added)
if claude plugin marketplace list --json 2>/dev/null \
   | jq -e '.[] | select(.name == "itc-claude-marketplace")' >/dev/null; then
  info "Marketplace itc-claude-marketplace already registered"
else
  # Use the HTTPS URL form (not the owner/repo short form). The short form makes
  # claude attempt an SSH clone, which fails on fresh distros that don't yet have
  # github.com's host key in ~/.ssh/known_hosts. HTTPS via gh credential helper
  # (configured above) authenticates without SSH known_hosts setup.
  claude plugin marketplace add https://github.com/screpeau-itc/itc-claude-marketplace
fi

# Install itc-base. Until the layer-2 batch creates this plugin, the install
# will fail; track success so the handoff step can degrade gracefully (launch
# claude without the slash command rather than handing into an "Unknown
# command: /itc-base-setup" prompt).
ITC_BASE_INSTALLED=n
if claude plugin list 2>/dev/null | grep -q "itc-base"; then
  info "Plugin itc-base already installed"
  ITC_BASE_INSTALLED=y
else
  if claude plugin install itc-base@itc-claude-marketplace 2>&1; then
    info "Installed plugin: itc-base"
    ITC_BASE_INSTALLED=y
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
if [[ "$ITC_BASE_INSTALLED" == "y" ]]; then
  info "Plugin: itc-base (installed)"
else
  info "Plugin: itc-base ${C_YELLOW}(not yet available — layer-2 work)${C_RESET}"
fi
if [[ "$WANT_DOCKER" == "y" ]]; then
  info "Docker: $(docker --version 2>/dev/null || echo 'installed')"
fi
echo

if [[ "$ENV_TYPE" == "wsl" ]]; then
  info "${C_YELLOW}WSL: run 'wsl --shutdown' from PowerShell to pick up /etc/wsl.conf changes.${C_RESET}"
  echo
fi

info "Launching Claude session in your workspace..."
sleep 2

cd "$WORKSPACE_DIR"
# Replace this shell with claude. Three FD details matter here:
#   1) stdin → /dev/tty: under `curl ... | bash`, bash's stdin is the script
#      pipe. Without redirection claude would inherit it and consume any
#      remaining bytes of install.sh as input (observed in T18).
#   2) stdout/stderr → /dev/tty: v0.4.6's auto-logging did `exec > >(tee ...)`
#      at the top of the script, so by this point fds 1 and 2 are pointed at
#      the tee subprocess pipe — NOT the operator's terminal directly.
#      claude inherits those tee'd FDs after exec, which (a) sends claude's
#      TUI through tee on its way to the terminal and (b) keeps tee alive as
#      an orphan until claude exits. That tee-attached state has been linked
#      to terminal-session teardown weirdness on /exit (operator dropping to
#      PowerShell instead of bash). Reattaching FDs directly to /dev/tty
#      here breaks the tee dependency and gives claude a clean attach.
#      The install log stops capturing at this point — acceptable, since
#      anything post-handoff is claude's own session, not install diagnostics.
#   3) The trailing line of install.sh is this exec — nothing after — so
#      even if a future edit forgets (1), there's no bash code left to leak.
# Only pass the slash command if the plugin actually installed; otherwise launch
# bare claude so the user doesn't land on an "Unknown command" prompt.
# Initial prompt as positional argument matches claude CLI 2.1.x convention.
# v0.4.4: slash command requires the plugin namespace prefix (/itc-base:itc-base-setup)
# — the bare /itc-base-setup form returns "Unknown command".
exec > /dev/tty 2>/dev/tty
if [[ "$ITC_BASE_INSTALLED" == "y" ]]; then
  exec claude "/itc-base:itc-base-setup" < /dev/tty
else
  info "${C_YELLOW}Launching bare claude — /itc-base:itc-base-setup will be available once the itc-base plugin ships.${C_RESET}"
  exec claude < /dev/tty
fi
