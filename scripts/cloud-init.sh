#!/usr/bin/env bash
# Cloud session init: PowerShell 7 + Pester 6.2.0 + PSScriptAnalyzer 1.25.0 (+ gitleaks 8.30.1).
# Paste into the cloud environment's setup script, or run: bash scripts/cloud-init.sh
# Versions match Test-Kit.ps1. Test-Kit.ps1 itself needs Windows PowerShell 5.1 and refuses
# PowerShell 7, so in the cloud run Pester and PSScriptAnalyzer directly (see end of output).
set -euo pipefail

PWSH_VERSION="${PWSH_VERSION:-7.4.6}"
PESTER_VERSION="6.2.0"
PSSA_VERSION="1.25.0"
GITLEAKS_VERSION="8.30.1"
PREFIX="${PREFIX:-$HOME/.local}"
SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"

case "$(uname -m)" in
  x86_64)  PWSH_ARCH="x64";   GL_ARCH="x64" ;;
  aarch64) PWSH_ARCH="arm64"; GL_ARCH="arm64" ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$PREFIX/bin"
export PATH="$PREFIX/bin:$PATH"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 1. PowerShell 7 from the GitHub release tarball (no apt repo needed)
if ! command -v pwsh >/dev/null; then
  # libicu and friends; ignore failure if already present or apt is unavailable
  $SUDO apt-get install -y --no-install-recommends libicu-dev ca-certificates curl >/dev/null 2>&1 || true
  curl -fsSL -o "$tmp/pwsh.tgz" \
    "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${PWSH_ARCH}.tar.gz"
  mkdir -p "$PREFIX/microsoft/powershell/${PWSH_VERSION}"
  tar -xzf "$tmp/pwsh.tgz" -C "$PREFIX/microsoft/powershell/${PWSH_VERSION}"
  chmod +x "$PREFIX/microsoft/powershell/${PWSH_VERSION}/pwsh"
  ln -sf "$PREFIX/microsoft/powershell/${PWSH_VERSION}/pwsh" "$PREFIX/bin/pwsh"
fi

# 2. Pinned modules
pwsh -NoProfile -NonInteractive -Command "
  \$ErrorActionPreference = 'Stop'
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  Install-Module -Name Pester -RequiredVersion $PESTER_VERSION -Scope CurrentUser -Force -SkipPublisherCheck
  Install-Module -Name PSScriptAnalyzer -RequiredVersion $PSSA_VERSION -Scope CurrentUser -Force
"

# 3. gitleaks, verified against the release checksums file
if ! command -v gitleaks >/dev/null; then
  base="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"
  file="gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz"
  curl -fsSL -o "$tmp/$file" "$base/$file"
  curl -fsSL -o "$tmp/checksums.txt" "$base/gitleaks_${GITLEAKS_VERSION}_checksums.txt"
  (cd "$tmp" && grep " $file\$" checksums.txt | sha256sum -c -)
  tar -xzf "$tmp/$file" -C "$PREFIX/bin" gitleaks
fi

# Persist PATH for later shells in this session
grep -q "$PREFIX/bin" "$HOME/.bashrc" 2>/dev/null || echo "export PATH=\"$PREFIX/bin:\$PATH\"" >> "$HOME/.bashrc"

pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString(); (Get-Module -ListAvailable Pester,PSScriptAnalyzer | Select-Object Name,Version | Format-Table | Out-String)'
gitleaks version
cat <<'MSG'

Run in the cloud (Test-Kit.ps1 is Windows PowerShell 5.1 only):
  pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"
  pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
MSG
