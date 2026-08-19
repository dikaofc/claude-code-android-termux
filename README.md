<div align="center">

<!-- ===== HERO BANNER ===== -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/dikaofc/claude-code-android-termux/main/assets/hero-dark.svg">
  <img src="https://raw.githubusercontent.com/dikaofc/claude-code-android-termux/main/assets/hero-dark.svg" alt="Claude Code on Android Termux" width="100%">
</picture>

<br>

[![License](https://img.shields.io/badge/license-MIT-ff6b35?style=for-the-badge&logo=opensourceinitiative&logoColor=white)](LICENSE)
[![Android](https://img.shields.io/badge/Android-3ddc84?style=for-the-badge&logo=android&logoColor=white)](https://termux.dev)
[![ARM64](https://img.shields.io/badge/ARM64-ff6b35?style=for-the-badge)](#)
[![Claude Code](https://img.shields.io/badge/Claude_Code-2.1.220-d97757?style=for-the-badge&logo=anthropic&logoColor=white)](https://github.com/anthropics/claude-code)
[![Stars](https://img.shields.io/github/stars/dikaofc/claude-code-android-termux?style=for-the-badge&color=ff6b35)](https://github.com/dikaofc/claude-code-android-termux/stargazers)

<br>

### **`$ claude --version`**
### **`2.1.220 (Claude Code)` · `ARM64` · `READY` ✅**

<br>

---

### ⚡ **ONE COMMAND — INSTANT SETUP**

```bash
curl -fsSL https://raw.githubusercontent.com/dikaofc/claude-code-android-termux/main/install.sh | bash
```

> 💀 `npm install` → `patchelf` → `LD_PRELOAD fix` → `verify` — fully automated, zero manual steps

---

### 🛠 **OR CLONE & RUN**

```bash
git clone https://github.com/dikaofc/claude-code-android-termux.git
cd claude-code-android-termux
bash install.sh
```

---

</div>

## 🧠 **What This Does**

> Claude Code is Anthropic's AI coding assistant for your terminal.
> It officially supports Linux/macOS — **not Android.**
> This project **bridges that gap** so you can run it natively on your phone.

### The Problem

| What happens | Why |
|---|---|
| `process.platform` returns `"android"` | Node.js reports Android, not Linux |
| npm maps to `linux-arm64-android` | That package **doesn't exist** |
| npm refuses `linux-arm64-musl` | OS mismatch: `android` ≠ `linux` |
| You get a 500-byte error stub | Instead of the ~250 MB native binary |

### The Fix (what the script does)

```
┌─────────────────────────────────────────────────────┐
│  npm install --force                                │
│    └─ bypass platform check                         │
│                                                     │
│  Patch install.cjs + cli-wrapper.cjs                │
│    └─ android → linux-arm64-musl                    │
│                                                     │
│  Download musl runtime (Alpine Linux aarch64)       │
│    └─ ld-musl-aarch64.so.1 + libc.musl-aarch64.so.1│
│                                                     │
│  Run postinstall → extract native binary            │
│                                                     │
│  patchelf --set-interpreter (musl linker path)      │
│  patchelf --set-rpath (musl libc path)              │
│                                                     │
│  Wrapper: unset LD_PRELOAD                          │
│    └─ strip bionic exec helper for musl compat      │
│                                                     │
│  ✅ claude --version → 2.1.220 (Claude Code)        │
└─────────────────────────────────────────────────────┘
```

---

## 📱 **Manual Install (Step by Step)**

<details>
<summary><b>🔍 Click to expand full manual guide</b></summary>

<br>

### Prerequisites

```bash
pkg update && pkg upgrade
pkg install nodejs npm curl git patchelf
```

> **Node.js ≥ 22.0.0** is required by Claude Code.

### Step 1 — Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code --force --ignore-scripts
```

### Step 2 — Patch platform detection

Edit **both** files — replace the android mapping with musl:

**`$PREFIX/lib/node_modules/@anthropic-ai/claude-code/install.cjs`**
**`$PREFIX/lib/node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs`**

```javascript
// BEFORE
if (platform === 'android') {
    return 'linux-' + cpu + '-android'
}

// AFTER
if (platform === 'android') {
    // Android (Termux) has no dedicated binary; use musl build
    return 'linux-' + cpu + '-musl'
}
```

### Step 3 — Install musl runtime

```bash
curl -fSL -o /tmp/musl.apk \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/musl-1.2.5-r11.apk"
mkdir -p /tmp/musl-extract
tar xzf /tmp/musl.apk -C /tmp/musl-extract 2>/dev/null
cp /tmp/musl-extract/lib/ld-musl-aarch64.so.1  "$PREFIX/lib/"
cp /tmp/musl-extract/lib/libc.musl-aarch64.so.1 "$PREFIX/lib/"
chmod 755 "$PREFIX/lib"/ld-musl-aarch64.so.1 "$PREFIX/lib"/libc.musl-aarch64.so.1
rm -rf /tmp/musl.apk /tmp/musl-extract
```

### Step 4 — Run postinstall

```bash
cd "$PREFIX/lib/node_modules/@anthropic-ai/claude-code"
node install.cjs
```

### Step 5 — Patch ELF binary

```bash
BINARY="$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" "$BINARY"
patchelf --set-rpath "$PREFIX/lib" "$BINARY"
```

### Step 6 — Fix LD_PRELOAD + DNS (bionic compat)

First, create a proot rootfs with a working `/etc/resolv.conf`:

```bash
mkdir -p ~/.claude-proot/etc/ssl/certs ~/.claude-proot/tmp
cat > ~/.claude-proot/etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chmod 1777 ~/.claude-proot/tmp
# Download CA certs for SSL
mkdir -p ~/.claude-proot/etc/ssl/certs
curl -fsSL -o ~/.claude-proot/etc/ssl/certs/ca-certificates.crt https://curl.se/ca/cacert.pem
cp ~/.claude-proot/etc/ssl/certs/ca-certificates.crt ~/.claude-proot/usr/local/share/ca-certificates/
```

Then create the wrapper:

```bash
# Remove npm symlink before creating wrapper
rm -f "$PREFIX/bin/claude"

cat > "$PREFIX/bin/claude" << 'WRAPPER'
#!/bin/sh
unset LD_PRELOAD

# Read API settings from settings.json if not in env
if [ -z "$ANTHROPIC_API_KEY" ] && [ -f "$HOME/.claude/settings.json" ]; then
  _key=$(grep -o '"ANTHROPIC_API_KEY"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
  [ -n "$_key" ] && export ANTHROPIC_API_KEY="$_key"
fi
export NODE_TLS_REJECT_UNAUTHORIZED="0"

PROOT_ROOT="$HOME/.claude-proot"
BINARY="$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"

if [ ! -d "$PROOT_ROOT/etc" ]; then
  exec "$BINARY" "$@"
fi

exec proot -r "$PROOT_ROOT" -b /dev -b /proc -b /sys -b "$PREFIX/bin:/bin" -b "$PREFIX/bin:/usr/bin" -b "$PREFIX/lib" -b "$PREFIX/lib:/usr/lib" -b "$PREFIX/tmp" -b /tmp -w "$HOME" --link2symlink "$BINARY" "$@"
WRAPPER
chmod +x "$PREFIX/bin/claude"
```

### Step 7 — Verify ✅

```bash
claude --version
# → 2.1.220 (Claude Code)
```

</details>

---

## 🔧 **How It Works**

<details>
<summary><b>🧬 Why musl?</b></summary>

<br>

| C Library | On Termux | Claude Code binary |
|-----------|-----------|-------------------|
| **bionic** (Android) | ✅ native | ❌ different ABI |
| **glibc** | ❌ not available | ❌ not available |
| **musl** | ❌ needs install | ✅ **binary is compiled against it** |

The `linux-arm64-musl` binary is linked against musl libc. We extract the musl linker + libc from Alpine Linux and place them in Termux's lib directory.

</details>

<details>
<summary><b>🔩 Why patchelf?</b></summary>

<br>

The binary's ELF header expects:

```
INTERP: /lib/ld-musl-aarch64.so.1
```

On Android:
- `/lib` → read-only symlink to `/system/lib`
- musl linker doesn't exist there

`patchelf` rewrites the header so the binary looks for the musl linker at `$PREFIX/lib/ld-musl-aarch64.so.1` instead.

</details>

<details>
<summary><b>🎯 Why unset LD_PRELOAD?</b></summary>

<br>

Termux injects `libtermux-exec-ld-preload.so` (bionic helper) into every process via `LD_PRELOAD`. The musl dynamic linker tries to load it and crashes because it can't resolve bionic symbols:

```
Error relocating libtermux-exec-ld-preload.so: __register_atfork: symbol not found
```

The wrapper unsets `LD_PRELOAD` before executing the binary.

</details>

---

## 🔄 **Updating**

```bash
# Re-run installer (idempotent — skips what's already done)
bash install.sh

# Or manual:
npm install -g @anthropic-ai/claude-code@latest --force --ignore-scripts
bash install.sh
```

---

## 🗑 **Uninstalling**

```bash
# Option 1
bash uninstall.sh

# Option 2
npm uninstall -g @anthropic-ai/claude-code
rm -f "$PREFIX/lib/ld-musl-aarch64.so.1"
rm -f "$PREFIX/lib/libc.musl-aarch64.so.1"
```

---

## 🐛 **Troubleshooting**

<details>
<summary><code>Error relocating libtermux-exec-ld-preload.so: __register_atfork: symbol not found</code></summary>

LD_PRELOAD conflict — re-run `bash install.sh` or manually create the wrapper:

```bash
cat > "$PREFIX/bin/claude" << 'EOF'
#!/bin/sh
unset LD_PRELOAD
exec "$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" "$@"
EOF
chmod +x "$PREFIX/bin/claude"
```

</details>

<details>
<summary><code>Error: claude native binary not installed</code></summary>

Postinstall didn't extract the binary. Re-run: `bash install.sh`

</details>

<details>
<summary><code>cannot execute: required file not found</code></summary>

Musl dynamic linker missing. Reinstall musl libs: `bash install.sh`

</details>

<details>
<summary><b>Shell commands not working inside Claude Code sessions</b></summary>

Claude Code can't spawn child processes (e.g. `node -v`, `ls`) because `/bin` and `/usr/bin` aren't mounted inside the proot rootfs.

**Fix:** Re-run `bash install.sh` — it will update the wrapper with the missing bind mounts.

**Or manually:**

```bash
# Remove npm symlink before creating wrapper
rm -f "$PREFIX/bin/claude"

cat > "$PREFIX/bin/claude" << 'WRAPPER'
#!/bin/sh
unset LD_PRELOAD

if [ -z "$ANTHROPIC_API_KEY" ] && [ -f "$HOME/.claude/settings.json" ]; then
  _key=$(grep -o '"ANTHROPIC_API_KEY"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
  [ -n "$_key" ] && export ANTHROPIC_API_KEY="$_key"
fi
export NODE_TLS_REJECT_UNAUTHORIZED="0"

PROOT_ROOT="$HOME/.claude-proot"
BINARY="$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"

if [ ! -d "$PROOT_ROOT/etc" ]; then
  exec "$BINARY" "$@"
fi

exec proot -r "$PROOT_ROOT" -b /dev -b /proc -b /sys -b "$PREFIX/bin:/bin" -b "$PREFIX/bin:/usr/bin" -b "$PREFIX/lib" -b "$PREFIX/lib:/usr/lib" -b "$PREFIX/tmp" -b /tmp -w "$HOME" --link2symlink "$BINARY" "$@"
WRAPPER
chmod +x "$PREFIX/bin/claude"
```

</details>

<details>
<summary><code>npm ERR! EBADPLATFORM</code></summary>

Expected on Android. Always use `--force` with npm install.

</details>

<details>
<summary><code>patchelf: command not found</code></summary>

```bash
pkg install patchelf
```

</details>

<details>
<summary><b>Node.js too old</b></summary>

Claude Code requires Node.js ≥ 22.0.0:

```bash
pkg install nodejs
node -v
```

</details>

<details>
<summary><code>Unable to connect to API</code> or API hangs</summary>

The musl binary uses its own DNS resolver that reads `/etc/resolv.conf`, which doesn't exist on Android (`/etc` is read-only). The install script wrapper automatically resolves hostnames via `curl` and uses the IP. If fixing manually:

1. Resolve the IP: `curl -s -o /dev/null -w '%{remote_ip}' "https://your-proxy.com"`
2. Update `~/.claude/settings.json` with the IP:
   ```json
   {
     "env": {
       "ANTHROPIC_BASE_URL": "https://RESOLVED_IP",
       "NODE_TLS_REJECT_UNAUTHORIZED": "0"
     }
   }
   ```

Or edit the wrapper at `$PREFIX/bin/claude` to add:
The wrapper uses proot to provide both DNS and CA certificates:

1. **DNS**: Proot provides `/etc/resolv.conf` with Google/Cloudflare nameservers
2. **SSL**: CA certificates from Mozilla are placed at `/etc/ssl/certs/ca-certificates.crt` inside the proot rootfs

Run `bash install.sh` to set this up automatically.

If fixing manually:

```bash
# Download CA certs
mkdir -p ~/.claude-proot/etc/ssl/certs
curl -fsSL -o ~/.claude-proot/etc/ssl/certs/ca-certificates.crt https://curl.se/ca/cacert.pem

# Also create resolv.conf
mkdir -p ~/.claude-proot/etc
echo 'nameserver 8.8.8.8' > ~/.claude-proot/etc/resolv.conf
```

</details>

---

## 📊 **Tested On**

| Device | Android | Termux | Node.js | Claude Code | Status |
|--------|---------|--------|---------|-------------|--------|
| aarch64 phone | 14+ | Latest | v26.x | v2.1.220 | ✅ |

---

## ⚠️ **Limitations**

- Binary is **~250 MB** — needs storage space
- Desktop GUI features won't work (expected on Termux)
- Will be unnecessary when Anthropic ships an official Android binary

---

## 🤝 **Credits**

- [Claude Code](https://github.com/anthropics/claude-code) by **Anthropic**
- [Termux](https://termux.dev) — Android terminal emulator
- [Alpine Linux](https://alpinelinux.org) — musl libc source

---

<div align="center">

### 💰 **Support This Project**

If this helped you run Claude Code on your phone, consider buying me a coffee ☕

<a href="https://saweria.co/dikatech">
  <img src="https://img.shields.io/badge/Donate-Saweria-ff6b35?style=for-the-badge&logo=kofi&logoColor=white" alt="Donate via Saweria">
</a>

---

### 🌐 **Connect with Developer**

<a href="https://t.me/dikaacode">
  <img src="https://img.shields.io/badge/Telegram-@dikaacode-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Telegram">
</a>
<a href="https://discord.gg/dikaalonely">
  <img src="https://img.shields.io/badge/Discord-@dikaalonely-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord">
</a>
<a href="https://instagram.com/xxcdicka">
  <img src="https://img.shields.io/badge/Instagram-@xxcdicka-E4405F?style=for-the-badge&logo=instagram&logoColor=white" alt="Instagram">
</a>
<a href="https://tiktok.com/@dikasecx">
  <img src="https://img.shields.io/badge/TikTok-@dikasecx-000000?style=for-the-badge&logo=tiktok&logoColor=white" alt="TikTok">
</a>

---

**Made with 🔥 by [@dikaacode](https://t.me/dikaacode)**

*Star ⭐ this repo if it helped you!*

</div>
