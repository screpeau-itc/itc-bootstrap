# itx-doctor.ps1 -- cross-platform shell entry to itx-doctor on Windows.
#
# Bootstraps a minimal toolchain (Python + claude CLI + marketplace +
# itx-doctor plugin) via winget, then invokes the doctor engine with
# any flags passed on the command line.
#
# Usage (PowerShell 5.1+ or pwsh):
#   .\itx-doctor.ps1                  # default: prompt-to-fix per gap
#   .\itx-doctor.ps1 --no-fix         # audit only
#   .\itx-doctor.ps1 --yes            # unattended
#   .\itx-doctor.ps1 --json           # machine-readable
#
# License: MIT.

[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)] [string[]]$DoctorArgs)

$ErrorActionPreference = 'Stop'

function Write-Ok($msg)   { Write-Host "[ok]   $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "[fail] $msg" -ForegroundColor Red; exit 1 }

# ─── Probe winget ──────────────────────────────────────────────────────────
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Fail "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}
Write-Ok "winget: $(winget --version)"

# ─── Ensure Python ─────────────────────────────────────────────────────────
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Host "[info] Python not on PATH; installing via winget..."
    winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
    # Refresh PATH within this session
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { Write-Fail "Python install completed but 'python' is still not on PATH. Open a new shell and re-run." }
}
Write-Ok "python: $($py.Source)"

# ─── Ensure claude CLI ─────────────────────────────────────────────────────
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    Write-Host "[info] claude CLI not on PATH; installing via winget..."
    winget install -e --id Anthropic.Claude --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) { Write-Fail "claude install completed but 'claude' is still not on PATH. Open a new shell and re-run." }
}
Write-Ok "claude: $(claude --version)"

# ─── Ensure marketplace registered ─────────────────────────────────────────
$mpProbe = & python -c "import sys,json,subprocess; r=subprocess.run(['claude','plugin','marketplace','list','--json'],capture_output=True,text=True); sys.exit(0 if r.returncode==0 and any(p.get('name')=='itx-claude-marketplace' for p in json.loads(r.stdout or '[]')) else 1)"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[info] Registering itx-claude-marketplace..."
    claude plugin marketplace add https://github.com/screpeau-itc/itx-claude-marketplace
}

# ─── Ensure itx-doctor plugin installed ────────────────────────────────────
$pluginList = claude plugin list 2>$null
if ($pluginList -notmatch 'itx-doctor') {
    Write-Host "[info] Installing itx-doctor plugin..."
    claude plugin install itx-doctor@itx-claude-marketplace
}

$doctorPy = & python -c "from pathlib import Path; print(str(Path.home() / '.claude' / 'plugins' / 'marketplaces' / 'itx-claude-marketplace' / 'plugins' / 'itx-doctor' / 'bin' / 'itx_doctor.py'))"
if (-not (Test-Path $doctorPy)) { Write-Fail "itx-doctor plugin not found at $doctorPy after install" }

# ─── Invoke ─────────────────────────────────────────────────────────────────
& python $doctorPy @DoctorArgs
exit $LASTEXITCODE
