# OpenCode Mobile Setup

Run [OpenCode](https://opencode.ai) from your iPhone. This repo has everything you need to go from zero to a fully working remote dev environment in under 15 minutes.

**What you get:**
- SSH into your Mac from anywhere via Tailscale (no port forwarding, no static IP)
- Mosh for bulletproof connections that survive network switches and iOS app suspension
- tmux so OpenCode keeps running when you disconnect
- SSH key auth (no typing your Mac password on a phone keyboard)

---

## Prerequisites

You need two things installed before running the script. The script checks for both and will exit with a clear error if either is missing.

### 1. Homebrew

Open Terminal and run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow the prompts. When it finishes, close and reopen Terminal.

### 2. Tailscale (standalone version)

> **Important:** Install the **standalone .pkg**, not the App Store version.
> The App Store version is sandboxed and doesn't expose the `tailscale` CLI that the script requires.

1. Go to **[pkgs.tailscale.com/stable/#macos](https://pkgs.tailscale.com/stable/#macos)**
2. Download the `.pkg` file
3. Open it and follow the installer
4. When macOS asks to allow the Tailscale system extension: go to **System Settings → Privacy & Security → Allow**
5. Tailscale.app will open — sign in or create a free account (Personal plan is free, no credit card)
6. In Terminal, confirm it's working:
   ```bash
   tailscale status
   ```
   You should see your machine listed as connected.

---

## Running the Script

**Option A — download and run directly:**

```bash
curl -fsSL https://raw.githubusercontent.com/alialfredji/opencode-mobile-setup/main/setup-remote-access.sh -o setup-remote-access.sh
chmod +x setup-remote-access.sh
./setup-remote-access.sh
```

**Option B — clone this repo:**

```bash
git clone https://github.com/alialfredji/opencode-mobile-setup.git
cd opencode-mobile-setup
chmod +x setup-remote-access.sh
./setup-remote-access.sh
```

The script will ask for your Mac password once (for sudo) and keeps it alive internally — you won't be prompted again mid-run.

**Expected runtime:** 2–5 minutes (most of the time is Homebrew installing tmux and mosh).

---

## What the Script Does

### Step 1 — Preflight checks
Verifies macOS, Homebrew, Tailscale CLI presence, and that you're signed into Tailscale. Exits with a clear error if anything is missing.

### Step 2 — Sudo access
Requests sudo once and keeps it alive in the background for the duration of the script.

### Step 3 — Enable Remote Login (SSH)
Turns on macOS's built-in SSH server. Equivalent to:

**System Settings → General → Sharing → Remote Login → ON**

Verifies that `sshd` is actually running after enabling.

### Step 4 — SSH keepalive + hardening
Appends to `/etc/ssh/sshd_config` (idempotent — safe to re-run):

| Setting | Value | Purpose |
|---------|-------|---------|
| `ClientAliveInterval` | `60` | Server pings client every 60 s to keep the connection alive |
| `ClientAliveCountMax` | `10` | Tolerates up to 10 missed pings (~10 min of silence) before dropping |
| `PermitRootLogin` | `no` | Blocks root SSH login |
| `AllowUsers` | your username | Whitelist — only your account can SSH in |
| `MaxAuthTries` | `3` | Rate-limits failed login attempts |

### Step 5 — SSH key setup
- Generates an `ed25519` key pair at `~/.ssh/id_ed25519` (skipped if one already exists)
- Adds the public key to `~/.ssh/authorized_keys` so your iPhone authenticates with it
- Sets `PasswordAuthentication no` — only key-based auth allowed from this point
- Restarts sshd to apply all settings from steps 4 and 5

At the end of the script, your full public key is printed for easy copy-paste into your iOS terminal app.

### Step 6 — Install tmux and mosh
Installs two tools via Homebrew (skipped if already installed):

- **tmux** — terminal multiplexer: keeps sessions alive after disconnect
- **mosh** — mobile shell: UDP-based protocol that survives network switches, cellular drops, and iOS app suspension

### Step 7 — Auto-attach tmux on SSH login
Appends to `~/.zshrc`:

```bash
if [[ -n "$SSH_CONNECTION" ]] && [[ -z "$TMUX" ]]; then
  tmux new-session -A -s main
fi
```

Every SSH or mosh connection automatically lands you in (or creates) a tmux session named `main`. OpenCode runs inside this session.

### Step 8 — tmux configuration
Writes `~/.tmux.conf` if it doesn't already exist (never overwrites an existing config). Sets:

- **Mouse support** — scroll with your finger on the phone screen
- **50,000 line scrollback** — review long OpenCode output without losing history
- **Fast escape key** — 10 ms instead of 500 ms default; critical for vim/neovim
- **Window numbering from 1** — easier to reach on a phone keyboard
- **[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)** — saves your tmux layout; survives Mac reboots
- **[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum)** — auto-saves every 15 min and auto-restores on boot

> **One manual step after first run:** open tmux and press `Ctrl+B` then `I` (capital I) to install the plugins. Takes ~10 seconds.

### Step 9 — Sleep / wake settings
Configures power management for AC power (MacBook battery behaviour is unaffected):

- `womp 1` — Wake on network access: a magic packet wakes the Mac from deep sleep
- `ttyskeepawake 1` — Mac stays awake while any SSH/mosh session is active; sleeps normally when you disconnect

> Your existing `remote-on` / `remote-off` aliases remain available for fully disabling sleep during long sessions.

### Step 10 — SSH config entry
Appends to `~/.ssh/config`:

```
Host mac-local
    HostName <your-tailscale-ip>
    User <your-username>
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 5
```

After this, `ssh mac-local` works from any device that has your private key. Blink Shell users can type `mosh mac-local` directly.

---

## iPhone Setup

The script handles everything on the Mac side. These steps are on your iPhone.

### 1. Install Tailscale for iOS

[App Store → Tailscale](https://apps.apple.com/app/tailscale/id1470499037)

- Sign in with the **same account** you used on your Mac
- Tap **Allow** when iOS asks to add a VPN configuration
- Your Mac should appear in the Tailscale device list

### 2. Install a Terminal App

| App | Protocol | Best for | Cost |
|-----|----------|----------|------|
| **[Moshi](https://apps.apple.com/app/id6757859949)** | mosh (native) | OpenCode workflows, voice input, push notifications | Free + IAP |
| **[Blink Shell](https://apps.apple.com/app/blink-shell/id1594898306)** | mosh + SSH | Power users, VS Code integration | ~$20/yr |
| **[Termius](https://apps.apple.com/app/termius-ssh-client/id549039908)** | SSH only | Simple SSH, solid free tier | Free + Premium |
| **[Prompt 3](https://apps.apple.com/app/prompt-3/id1594420480)** | SSH only | Clean UI, one-time purchase | ~$15 |

Moshi is the best fit for OpenCode — it's designed specifically for AI coding agent workflows.

### 3. Add Your Mac as a Host

The script prints your Tailscale IP and full SSH public key at the end. Have those ready.

**In Moshi:**
1. Tap **+** → New Connection
2. Hostname: your Tailscale IP (or MagicDNS hostname if enabled)
3. Username: your Mac username
4. Auth: paste the public key printed by the script

**In Blink Shell:**
1. Settings → Hosts → **+**
2. Fill in Alias (`mac`), Hostname (Tailscale IP), User
3. Keys section: paste the public key printed by the script
4. Mosh Parameters → Server path:
   - Apple Silicon Mac: `/opt/homebrew/bin/mosh-server`
   - Intel Mac: `/usr/local/bin/mosh-server`

**In Termius:**
1. Keychain tab → **+ New Key** → Generate → ED25519 → save
2. Long-press the key → Export to host — or copy the public key and paste it into `~/.ssh/authorized_keys` on your Mac

### 4. Connect

Tap your saved host — you'll land directly in the tmux session. Then:

```bash
opencode
```

---

## Daily Workflow

```
iPhone → Moshi/Blink → mosh to Mac → auto-attaches tmux → run opencode
```

| Situation | What happens |
|-----------|-------------|
| Switch apps on iPhone | mosh reconnects automatically when you return |
| Cellular → WiFi (or back) | mosh handles the network change seamlessly |
| Close the terminal app entirely | tmux keeps the session alive on your Mac |
| Reopen terminal and connect | back in your session, OpenCode still running |
| Mac reboots | tmux-continuum restores your session layout automatically |

---

## Useful Commands

```bash
# Detach from tmux (leave everything running in background)
Ctrl+B  D

# New tmux window
Ctrl+B  C

# Switch between windows
Ctrl+B  1 / 2 / 3

# Scroll mode — use your finger to scroll when mouse is on
Ctrl+B  [      (press q to exit)

# List all tmux sessions
tmux ls

# Manually save tmux layout (tmux-resurrect)
Ctrl+B  Ctrl+S

# Manually restore saved layout
Ctrl+B  Ctrl+R

# Keep Mac fully awake on AC (your alias)
remote-on

# Let Mac sleep normally again
remote-off
```

---

## Troubleshooting

**"Connection refused" when connecting**
- Check Remote Login is still on: System Settings → General → Sharing → Remote Login
- Verify sshd is running: `pgrep sshd` (should return a PID)

**Mosh says "mosh-server not found"**
- In your terminal app's host config, set the mosh-server path explicitly:
  - Apple Silicon: `/opt/homebrew/bin/mosh-server`
  - Intel: `/usr/local/bin/mosh-server`

**Can't connect at all**
- Verify Tailscale is active on both Mac and iPhone
- Both devices should appear at [login.tailscale.com](https://login.tailscale.com)
- Try pinging the Tailscale IP from your phone's terminal app: `ping <tailscale-ip>`

**tmux plugins didn't install after first run**
- Open a tmux session: `tmux`
- Press `Ctrl+B` then `I` (capital I)
- Wait ~10 seconds, then press Enter

**Mac fell asleep before you could connect**
- Run `remote-on` at the start of any long session to prevent sleep entirely
- `ttyskeepawake` only prevents sleep while a session is already active — it can't wake a Mac that already slept
- `womp` (wake on network) handles cold-start wake via Tailscale magic packet
