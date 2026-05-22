# itc-bootstrap

Cold-start installer that takes a bare Ubuntu/Debian (including a fresh WSL distro) from `apt update` to a working Claude Code state with the `itc-claude-marketplace` registered and the `itc-base` plugin installed.

After this installer finishes, you have:
- A `~/dev/<workspace-name>` folder pre-trusted in Claude Code's config
- Claude CLI installed and authenticated to your Anthropic account
- GitHub CLI installed and authenticated with scopes `repo,workflow,read:org,read:public_key`
- (Optional) An SSH server with your GitHub-registered public keys in `authorized_keys`
- A Claude Code session opened in the workspace, ready to invoke `/itc-base-setup` for the layer-2 setup

## Quick start

On a freshly-installed Ubuntu/Debian (or WSL distro), paste this into your terminal:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl
curl -fsSL "https://raw.githubusercontent.com/screpeau-itc/itc-bootstrap/main/install.sh?v=$(date +%s)" | bash
```

The installer asks two questions upfront, then runs uninterrupted until it pauses for Claude Code's browser authentication and GitHub's browser authentication. Plan ~15–20 minutes for the full run.

## What the installer does

1. **Detects** distro (Ubuntu/Debian only — bails on others with manual-mode pointer) and environment (WSL, Docker, LXC, VM, native).
2. **Asks** two quick questions: workspace folder name (default `itx-default-code`), enable inbound SSH (default Yes on WSL/Docker/LXC/VM, No on native).
3. **Installs base packages**: `build-essential git ca-certificates gnupg lsb-release jq tmux unzip`.
4. **Writes `/etc/wsl.conf`** (WSL only): enables systemd, sets default user, mounts `/mnt/c` **read-only** (Windows files visible but not writable from WSL), disables Windows PATH inheritance.
5. **Creates the workspace directory** under `~/dev/<chosen-name>`.
6. **Pre-stages Claude Code's trust config** so the workspace doesn't trigger the "Do you trust this directory?" prompt on first run.
7. **Installs Node LTS** via NodeSource.
8. **Installs Claude Code CLI** (`npm install -g @anthropic-ai/claude-code`) and pauses for browser auth.
9. **Installs GitHub CLI** and runs `gh auth login --scopes repo,workflow,read:org,read:public_key`.
10. **Configures inbound SSH** (if enabled): installs `openssh-server`, fetches your GitHub-registered SSH pubkeys, lets you pick which to install in `~/.ssh/authorized_keys`. Optional: add another GitHub user's keys.
11. **Registers `itc-claude-marketplace`** and **installs `itc-base`** plugin.
12. **Hands off** to a Claude session opened in your workspace with `/itc-base-setup` invoked.

## What this does NOT do

This installer is intentionally minimal. The following are deferred to layer-2 work (the `itc-base` plugin's `/itc-base-setup` skill) or to role-specific plugins:

- Git identity (`user.name`, `user.email`)
- Outbound SSH key generation (only set up when a specific workflow needs it)
- Cloning project repos (the `itc-workspace` plugin handles ispe; other plugins handle their respective repos)
- Role-specific tooling — Go, Playwright, postgresql-client, Python venv tooling, Grafana stack, Docker engine — all live in opt-in plugins
- `~/.claude/settings.json` customization beyond the trust config
- Custom hooks
- Tool-version managers (mise/asdf) — single-version pins are used by each role plugin instead

## Manual mode

If you're on a distro the installer doesn't support (anything besides Ubuntu/Debian), or you prefer to walk through the steps yourself, here's the equivalent sequence. Adapt the package-manager commands for your distro.

### 1. Base packages

```bash
sudo apt-get update && sudo apt-get install -y \
  build-essential git ca-certificates gnupg lsb-release jq tmux unzip curl
```

### 2. WSL overlay (WSL only)

```bash
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true

[user]
default=screpeau

[interop]
appendWindowsPath=false

[automount]
options="ro"
EOF
# From PowerShell on the Windows host:
#   wsl --shutdown
# Then re-enter WSL to pick up the changes.
```

### 3. Workspace directory

```bash
mkdir -p ~/dev/itx-default-code
```

### 4. Pre-stage Claude trust config

```bash
cat > ~/.claude.json <<EOF
{
  "projects": {
    "$HOME/dev/itx-default-code": {
      "hasTrustDialogAccepted": true
    }
  }
}
EOF
chmod 600 ~/.claude.json
```

### 5. Node LTS

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### 6. Claude Code CLI

```bash
sudo npm install -g @anthropic-ai/claude-code
claude        # complete browser auth, then exit
```

### 7. GitHub CLI

```bash
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update && sudo apt-get install -y gh
gh auth login --scopes "repo,workflow,read:org,read:public_key" --hostname github.com --git-protocol https --web
```

### 8. Inbound SSH (optional, if accessing this box remotely)

```bash
sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
gh ssh-key list   # see what's registered to your GitHub account
# Pick the public-key value from the JSON output and add it:
gh ssh-key list --json key --jq '.[].key' | head -1 >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### 9. Marketplace + base plugin

```bash
claude plugin marketplace add screpeau-itc/itc-claude-marketplace
claude plugin install itc-base@itc-claude-marketplace
```

### 10. Open the workspace

```bash
cd ~/dev/itx-default-code
claude "/itc-base-setup"
```

## Troubleshooting

**"Distro not supported" error**: MVP supports Ubuntu and Debian. For other distros, follow the manual-mode steps above with your distro's package manager.

**Script fails partway, want to re-run**: every step is idempotent. Fix the underlying issue (network, auth, etc.) and re-run the curl-pipe-bash recipe. Already-completed steps will print `○ skipped`.

**`claude plugin install itc-base` reports "plugin not found"**: expected during the layer-1-only phase. The `itc-base` plugin is being built in a follow-up batch. The installer treats this as a non-fatal warning and continues to the hand-off step, where you'll land in a Claude session that can be used immediately even without the plugin installed.

**Inbound SSH on WSL: "I can't reach it from my phone / another machine"**: WSL2 networking is NAT'd behind the Windows host. The SSH server's IP (printed at the end of the install) is reachable from the Windows host only, and rerolls each `wsl --shutdown`. External reach requires `netsh portproxy` on the Windows side (not recommended) or ZeroTier inside the distro (deferred — see the spec).

**"Do you trust this directory?" prompt still appears**: the trust-config schema may have changed in a newer Claude Code version. Verify `~/.claude.json` contains an entry for your workspace path under `projects`. If not, manually accept the prompt (one-time per directory).

## License

MIT — see [LICENSE](LICENSE).

## Related

- [`screpeau-itc/itc-claude-marketplace`](https://github.com/screpeau-itc/itc-claude-marketplace) — the Claude Code marketplace this installer registers (currently private; access required).
- ispe (`itx-shared-programing-environment`) — the operator's workspace itself; cloned by the future `itc-workspace` plugin.
