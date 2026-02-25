#!/usr/bin/env bash
# =============================================================================
# setup-remote-access.sh
# Mac-side setup: Tailscale + SSH + tmux + mosh for iPhone OpenCode access
# =============================================================================

set -euo pipefail

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

ok()     { echo -e "${GREEN}  ✓${RESET}  $*"; }
warn()   { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
err()    { echo -e "${RED}  ✗${RESET}  $*"; }
info()   { echo -e "${BLUE}  →${RESET}  $*"; }
header() { echo -e "\n${BOLD}$*${RESET}"; }

# --- Helpers -----------------------------------------------------------------

require_sudo() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "\n${BOLD}This script needs sudo for a few steps:${RESET}"
    echo "  • Enabling Remote Login (SSH)"
    echo "  • Updating /etc/ssh/sshd_config (keepalive + hardening)"
    echo "  • Setting wake-on-network (pmset)"
    echo "  • Setting ttyskeepawake (pmset)"
    echo ""
    sudo -v || { err "sudo authentication failed"; exit 1; }
    # Keep sudo alive in background
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

file_contains() {
  grep -qF "$1" "$2" 2>/dev/null
}

# =============================================================================
echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Mac Remote Access Setup${RESET}"
echo -e "${BOLD}  Tailscale + SSH + tmux + mosh${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

# =============================================================================
header "Step 1/10 — Preflight checks"

# macOS check
if [[ "$(uname)" != "Darwin" ]]; then
  err "This script is macOS only."
  exit 1
fi
ok "macOS detected: $(sw_vers -productVersion)"

# Homebrew
if command -v brew &>/dev/null; then
  ok "Homebrew found: $(brew --version | head -1)"
else
  err "Homebrew is not installed. Install it first:"
  echo "      /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  exit 1
fi

# Tailscale CLI
if command -v tailscale &>/dev/null; then
  ok "Tailscale CLI found"
elif [[ -f "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
  # Standalone app ships CLI at this path but may not be on PATH
  export PATH="$PATH:/Applications/Tailscale.app/Contents/MacOS"
  ok "Tailscale CLI found (via app bundle)"
else
  warn "Tailscale does not appear to be installed."
  echo ""
  echo "      Download the Standalone .pkg (NOT App Store) from:"
  echo "      https://pkgs.tailscale.com/stable/#macos"
  echo ""
  echo "      Then re-run this script."
  exit 1
fi

# Tailscale connected?
TAILSCALE_STATUS=$(tailscale status 2>&1 || true)
if echo "$TAILSCALE_STATUS" | grep -q "Logged out\|not logged in\|NeedsLogin"; then
  warn "Tailscale is installed but you are not signed in."
  echo "      Run: tailscale up"
  echo "      Then re-run this script."
  exit 1
fi
ok "Tailscale is signed in and connected"

# =============================================================================
header "Step 2/10 — Requesting sudo access"
require_sudo

# Resolve MAC_USER early — needed for sshd_config AllowUsers
MAC_USER=$(whoami)

# =============================================================================
header "Step 3/10 — Enable Remote Login (SSH)"

REMOTE_LOGIN=$(sudo systemsetup -getremotelogin 2>/dev/null | awk '{print $NF}')
if [[ "$REMOTE_LOGIN" == "On" ]]; then
  ok "Remote Login already enabled"
else
  info "Enabling Remote Login..."
  sudo systemsetup -setremotelogin on
  ok "Remote Login enabled"
fi

# Verify sshd is running
if pgrep -x sshd &>/dev/null; then
  ok "sshd is running"
else
  warn "sshd doesn't appear to be running — try toggling Remote Login in System Settings"
fi

# =============================================================================
header "Step 4/10 — SSH keepalive + hardening (sshd_config)"

SSHD_CONFIG="/etc/ssh/sshd_config"
NEEDS_RESTART=false

# --- Keepalive ---------------------------------------------------------------
if file_contains "ClientAliveInterval 60" "$SSHD_CONFIG"; then
  ok "ClientAliveInterval already set"
else
  info "Adding ClientAliveInterval 60 to $SSHD_CONFIG..."
  echo "" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  echo "# Added by setup-remote-access.sh — SSH keepalive for mobile sessions" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  echo "ClientAliveInterval 60" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  ok "ClientAliveInterval 60 added"
  NEEDS_RESTART=true
fi

if file_contains "ClientAliveCountMax 10" "$SSHD_CONFIG"; then
  ok "ClientAliveCountMax already set"
else
  info "Adding ClientAliveCountMax 10 to $SSHD_CONFIG..."
  echo "ClientAliveCountMax 10" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  ok "ClientAliveCountMax 10 added"
  NEEDS_RESTART=true
fi

# --- Hardening ---------------------------------------------------------------
if file_contains "PermitRootLogin no" "$SSHD_CONFIG"; then
  ok "PermitRootLogin already set to no"
else
  info "Setting PermitRootLogin no..."
  echo "" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  echo "# Added by setup-remote-access.sh — hardening" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  echo "PermitRootLogin no" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  ok "PermitRootLogin no added"
  NEEDS_RESTART=true
fi

if file_contains "AllowUsers $MAC_USER" "$SSHD_CONFIG"; then
  ok "AllowUsers already set"
else
  info "Restricting SSH to current user ($MAC_USER)..."
  echo "AllowUsers $MAC_USER" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  ok "AllowUsers $MAC_USER added"
  NEEDS_RESTART=true
fi

if file_contains "MaxAuthTries 3" "$SSHD_CONFIG"; then
  ok "MaxAuthTries already set"
else
  info "Setting MaxAuthTries 3..."
  echo "MaxAuthTries 3" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  ok "MaxAuthTries 3 added"
  NEEDS_RESTART=true
fi

# sshd restart deferred — will happen after PasswordAuthentication is set in Step 5

# =============================================================================
header "Step 5/10 — SSH key setup (ed25519)"

SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

# Ensure ~/.ssh exists with correct permissions
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$SSH_KEY" ]]; then
  ok "ed25519 key already exists: $SSH_KEY"
else
  info "Generating ed25519 SSH key pair..."
  ssh-keygen -t ed25519 -C "iphone-$(date +%Y)" -f "$SSH_KEY" -N ""
  ok "Key generated: $SSH_KEY"
fi

# Ensure the public key is in authorized_keys (idempotent)
PUB_KEY=$(cat "${SSH_KEY}.pub")
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
if grep -qF "$PUB_KEY" "$AUTH_KEYS" 2>/dev/null; then
  ok "Public key already in authorized_keys"
else
  echo "$PUB_KEY" >> "$AUTH_KEYS"
  ok "Public key added to authorized_keys"
fi

# Disable password auth — keys are now in place
if file_contains "PasswordAuthentication no" "$SSHD_CONFIG"; then
  ok "PasswordAuthentication already disabled"
else
  info "Disabling password authentication (key-only from now on)..."
  echo "PasswordAuthentication no" | sudo tee -a "$SSHD_CONFIG" > /dev/null
  ok "PasswordAuthentication no added"
  NEEDS_RESTART=true
fi

# Restart sshd now that all sshd_config changes are done
if [[ "$NEEDS_RESTART" == true ]]; then
  info "Restarting sshd to apply config changes..."
  sudo launchctl stop com.openssh.sshd 2>/dev/null || true
  sleep 1
  ok "sshd restarted"
fi

# =============================================================================
header "Step 6/10 — Install tmux + mosh"

if command -v tmux &>/dev/null; then
  ok "tmux already installed: $(tmux -V)"
else
  info "Installing tmux via Homebrew..."
  brew install tmux
  ok "tmux installed: $(tmux -V)"
fi

if command -v mosh &>/dev/null; then
  ok "mosh already installed: $(mosh --version 2>&1 | head -1)"
else
  info "Installing mosh via Homebrew..."
  brew install mosh
  ok "mosh installed: $(mosh --version 2>&1 | head -1)"
fi

# =============================================================================
header "Step 7/10 — Auto-attach tmux on SSH login"

ZSHRC="$HOME/.zshrc"
TMUX_SNIPPET='
# Auto-attach to tmux when connecting via SSH (OpenCode remote access)
if [[ -n "$SSH_CONNECTION" ]] && [[ -z "$TMUX" ]]; then
  tmux new-session -A -s main
fi'

if file_contains 'tmux new-session -A -s main' "$ZSHRC"; then
  ok "tmux auto-attach snippet already in ~/.zshrc"
else
  info "Appending tmux auto-attach snippet to ~/.zshrc..."
  echo "$TMUX_SNIPPET" >> "$ZSHRC"
  ok "Snippet added to ~/.zshrc"
fi

# =============================================================================
header "Step 8/10 — tmux configuration (~/.tmux.conf)"

TMUX_CONF="$HOME/.tmux.conf"

if [[ -f "$TMUX_CONF" ]]; then
  ok "~/.tmux.conf already exists — skipping (not overwriting)"
  info "Tip: add 'set -g mouse on' for finger-scroll support on iPhone"
else
  info "Writing ~/.tmux.conf (mouse scroll, large history, tmux-resurrect)..."
  cat > "$TMUX_CONF" << 'TMUXEOF'
# -----------------------------------------------
# ~/.tmux.conf — optimised for iPhone / OpenCode
# -----------------------------------------------

# Mouse support (scroll with finger on phone screen)
set -g mouse on

# Large scrollback buffer
set -g history-limit 50000

# Fast escape key (critical for vim/neovim)
set -sg escape-time 10

# Modern terminal colours
set -g default-terminal "screen-256color"

# Status bar: show session name and time
set -g status-right "#[fg=colour240]%H:%M "

# Window numbering starts at 1 (easier on phone keyboard)
set -g base-index 1
setw -g pane-base-index 1

# Renumber windows when one is closed
set -g renumber-windows on

# -----------------------------------------------
# Plugin Manager (TPM)
# To install plugins: prefix + I (capital i)
# -----------------------------------------------
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'   # persist sessions across reboots
set -g @plugin 'tmux-plugins/tmux-continuum'   # auto-save + auto-restore

# Auto-restore last saved environment on tmux start
set -g @continuum-restore 'on'

# Initialize TPM (keep this at the very bottom)
run '~/.tmux/plugins/tpm/tpm'
TMUXEOF
  ok "~/.tmux.conf written"

  # Install TPM
  if [[ -d "$HOME/.tmux/plugins/tpm" ]]; then
    ok "TPM already installed"
  else
    info "Installing TPM (tmux Plugin Manager)..."
    git clone --depth=1 https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
    ok "TPM installed — once in tmux, press Ctrl+B I to install plugins"
  fi
fi

# =============================================================================
header "Step 9/10 — Sleep / wake settings (pmset)"

# Wake on network access — use -c (AC only) on a MacBook
WOMP=$(pmset -g | awk '/womp/ {print $2}')
if [[ "$WOMP" == "1" ]]; then
  ok "Wake on network access (womp) already enabled"
else
  info "Enabling Wake on network access (AC power)..."
  sudo pmset -c womp 1
  ok "Wake on network access enabled"
fi

# ttyskeepawake — Mac stays awake while an SSH session is active, sleeps normally otherwise
TTYS=$(pmset -g | awk '/ttyskeepawake/ {print $2}')
if [[ "$TTYS" == "1" ]]; then
  ok "ttyskeepawake already enabled"
else
  info "Enabling ttyskeepawake (Mac stays awake during active SSH sessions)..."
  sudo pmset -c ttyskeepawake 1
  ok "ttyskeepawake enabled"
fi

info "Tip: use 'remote-on' alias to fully disable AC sleep for long unattended sessions"

# =============================================================================
header "Step 10/10 — SSH config entry (~/.ssh/config)"

SSH_CONFIG="$HOME/.ssh/config"
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unavailable")

if file_contains "Host mac-local" "$SSH_CONFIG"; then
  ok "SSH config entry for 'mac-local' already exists"
else
  info "Adding 'mac-local' convenience entry to ~/.ssh/config..."
  mkdir -p "$SSH_DIR"
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  cat >> "$SSH_CONFIG" << EOF

# Added by setup-remote-access.sh — Tailscale Mac access
Host mac-local
    HostName ${TAILSCALE_IP}
    User ${MAC_USER}
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 5
EOF
  ok "SSH config entry added — 'ssh mac-local' works from any device on your tailnet"
fi

# =============================================================================
# Summary
# =============================================================================

TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
self = d.get('Self', {})
dns = self.get('DNSName', '')
print(dns.rstrip('.') if dns else 'unavailable')
" 2>/dev/null || echo "unavailable")

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Setup Complete — Connection Details${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo -e "  ${BOLD}Mac username:${RESET}        $MAC_USER"
echo -e "  ${BOLD}Tailscale IP:${RESET}        $TAILSCALE_IP"
echo -e "  ${BOLD}Tailscale hostname:${RESET}  $TAILSCALE_HOSTNAME"
echo ""
echo -e "  ${BOLD}SSH command:${RESET}"
echo -e "  ${BLUE}ssh ${MAC_USER}@${TAILSCALE_IP}${RESET}"
echo ""
echo -e "  ${BOLD}Mosh command (recommended — survives network changes):${RESET}"
echo -e "  ${BLUE}mosh ${MAC_USER}@${TAILSCALE_IP} -- tmux new -As main${RESET}"
echo ""

echo -e "${BOLD}iPhone steps (do these manually):${RESET}"
echo "  1. Install Tailscale from the App Store → sign in with the same account"
echo "  2. Install a terminal app:"
echo "       • Moshi (best for OpenCode, mosh+voice) → App Store / getmoshi.app"
echo "       • Blink Shell (~\$20/yr, mosh+SSH)       → App Store"
echo "       • Termius (SSH only, free tier)          → App Store"
echo "       • Prompt 3 (SSH only, one-time ~\$15)    → App Store"
echo "  3. In the app, add a new host:"
echo "       Hostname : ${TAILSCALE_IP}"
echo "       Username : ${MAC_USER}"
echo "       Auth     : SSH key — copy the public key printed below into the app"
echo ""

echo -e "${BOLD}Your SSH public key (paste into Termius / Blink / Moshi):${RESET}"
echo -e "${BLUE}$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo 'key not found — check ~/.ssh/id_ed25519.pub')${RESET}"
echo ""

echo -e "${BOLD}How it works once set up:${RESET}"
echo "  • Connect via mosh (or SSH) → lands in tmux session 'main'"
echo "  • Run: opencode"
echo "  • Switch networks / lose signal → mosh reconnects automatically"
echo "  • Disconnect anytime — OpenCode keeps running in tmux"
echo "  • Reconnect → automatically reattaches to the same session"
echo ""

echo -e "${BOLD}Useful tmux commands:${RESET}"
echo "  Ctrl+B  D    detach (leave session running)"
echo "  Ctrl+B  C    new window"
echo "  Ctrl+B  [    scroll mode (q to exit) — or just use mouse/finger"
echo "  tmux ls      list sessions"
echo ""

echo -e "${GREEN}${BOLD}All done. Happy coding from the couch.${RESET}"
echo ""
