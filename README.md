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
[![Claude Code](https://img.shields.io/badge/Claude_Code-2.1.236-d97757?style=for-the-badge&logo=anthropic&logoColor=white)](https://github.com/anthropics/claude-code)
[![Stars](https://img.shields.io/github/stars/dikaofc/claude-code-android-termux?style=for-the-badge&color=ff6b35)](https://github.com/dikaofc/claude-code-android-termux/stargazers)

<br>

### **`$ claude --version`**
### **`2.1.236 (Claude Code)` · `ARM64` · `READY` ✅**

<br>

---

### ⚡ **ONE COMMAND — INSTANT SETUP**

```bash
git clone https://github.com/dikaofc/claude-code-android-termux.git
cd claude-code-android-termux
sh install.sh
```

> `sh install.sh` works — the script auto-re-invokes itself with `bash`.
> Fully automated: npm install → musl runtime → ELF patch → no-root DNS fix → verify.

---

### 🛠 **OR PIPE IT**

```bash
curl -fsSL https://raw.githubusercontent.com/dikaofc/claude-code-android-termux/main/install.sh | bash
```

---

</div>

## 🧠 **What This Does**

> Claude Code is Anthropic's AI coding assistant for your terminal.
> It officially supports Linux/macOS — **not Android.**
> This project **bridges that gap** so you can run it natively on your phone
> — **no root, no proot** required.

### The Problem

| What happens | Why |
|---|---|
| `process.platform` returns `"android"` | Node.js reports Android, not Linux |
| npm maps to `linux-arm64-android` | That package **doesn't exist** |
| npm refuses `linux-arm64-musl` | OS mismatch: `android` ≠ `linux` |
| You get a 500-byte error stub | Instead of the ~310 MB native binary |

### The Fix (what the script does)

```
┌─────────────────────────────────────────────────────┐
│  npm install --force                                │
│    └─ bypass platform check                         │
│                                                     │
│  Patch install.cjs + cli-wrapper.cjs                │
│    └─ android → linux-arm64-musl                    │
│                                                     │
│  Install musl runtime (Alpine Linux aarch64)        │
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
│  dnsproxy.py (no-root DNS fix)                      │
│    └─ auto-started on 127.0.0.1:8080, HTTPS_PROXY   │
│                                                     │
│  ✅ claude --version → 2.1.236 (Claude Code)        │
└─────────────────────────────────────────────────────┘
```

---

## 💥 **The DNS Problem (Why Claude Used to Hang)**

If you previously ran `claude` and it stuck on
**`API error · Retrying...`** forever, this was why:

- The Claude Code binary is **Bun (musl)**.
- Bun resolves DNS itself with c-ares, which reads **`/etc/resolv.conf`**.
- On Android, `/etc` is a read-only symlink to `/system/etc` —
  **`/etc/resolv.conf` simply does not exist.**
- With no resolv.conf, DNS queries fall back to `127.0.0.1:53`, which nobody
  answers → the API host can never be resolved → retry forever.

`curl`, `npm`, and `node` work fine because they use **Android's native
resolver** (bionic). The musl binary is the only one that's broken.

## 🔧 **The No-Root DNS Fix (dnsproxy.py)**

We don't fight the read-only filesystem. Instead we **sidestep** it:

1. `dnsproxy.py` is a tiny HTTP **CONNECT proxy** (~60 lines, pure `python3`).
2. The `claude` wrapper auto-starts it on `127.0.0.1:8080` when needed,
   then exports `HTTPS_PROXY`/`HTTP_PROXY` at it.
3. The musl binary sends its HTTPS traffic through the proxy.
4. The proxy resolves hostnames with **Android's own resolver**
   (`socket.getaddrinfo` → bionic → works perfectly), then tunnels the bytes.

```
claude.exe (musl)  ──HTTPS_PROXY──▶  127.0.0.1:8080  dnsproxy.py
  "resolve rx8lx48.abc-tunnel.us"  ──▶  getaddrinfo() (bionic) ✅
  <──── CONNECT tunnel (raw TLS) ────▶  rx8lx48.abc-tunnel.us:443 ✅
```

- **No root** — no privileged ports, no `/etc` writes.
- **No proot** — no chroot, no bind mounts, no child-process crashes.
- **Universal** — works on any device, rooted or not.
- The proxy is checked/restarted automatically by the wrapper on every run.

---

## 📱 **Manual Install (Step by Step)**

<details>
<summary><b>🔍 Click to expand full manual guide</b></summary>

<br>

### Prerequisites

```bash
pkg update && pkg upgrade
pkg install nodejs npm curl git patchelf python3
```

> **Node.js ≥ 22.0.0** is required by Claude Code. Python 3 is used only by
> the DNS proxy (no root needed).

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
curl -fSL -o "$PREFIX/tmp/musl.apk" \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/musl-1.2.5-r12.apk"
mkdir -p "$PREFIX/tmp/musl-extract"
tar xzf "$PREFIX/tmp/musl.apk" -C "$PREFIX/tmp/musl-extract" 2>/dev/null
cp "$PREFIX/tmp/musl-extract/lib/ld-musl-aarch64.so.1"  "$PREFIX/lib/"
cp "$PREFIX/tmp/musl-extract/lib/libc.musl-aarch64.so.1" "$PREFIX/lib/"
chmod 755 "$PREFIX/lib"/ld-musl-aarch64.so.1 "$PREFIX/lib"/libc.musl-aarch64.so.1
rm -rf "$PREFIX/tmp/musl.apk" "$PREFIX/tmp/musl-extract"
```

> Uses `$PREFIX/tmp` (a real writable dir) — Android's `/tmp` is not writable.

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

### Step 6 — DNS proxy (no-root fix)

```bash
cp assets/dnsproxy.py "$PREFIX/bin/dnsproxy.py"
chmod +x "$PREFIX/bin/dnsproxy.py"
```

### Step 7 — Create the wrapper

```bash
# Remove npm symlink before creating wrapper
rm -f "$PREFIX/bin/claude"

cat > "$PREFIX/bin/claude" << 'WRAPPER'
#!/bin/sh
unset LD_PRELOAD
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Read API settings from settings.json if not in env
if [ -f "$HOME/.claude/settings.json" ]; then
  for _v in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL; do
    if [ -z "$(eval echo \$$_v)" ]; then
      _val=$(grep -o "\"$_v\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
      [ -n "$_val" ] && export "$_v=$_val"
    fi
  done
fi
export NODE_TLS_REJECT_UNAUTHORIZED="0"

# Auto-start the no-root DNS proxy, then route the binary through it
if [ -x "$PREFIX/bin/python3" ] && [ -f "$PREFIX/bin/dnsproxy.py" ]; then
  _port="${CLAUDE_DNS_PROXY_PORT:-8080}"
  if ! "$PREFIX/bin/python3" - "$_port" >/dev/null 2>&1 <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
  then
    setsid "$PREFIX/bin/python3" "$PREFIX/bin/dnsproxy.py" "$_port" \
      >"$PREFIX/tmp/dnsproxy.log" 2>&1 </dev/null &
    sleep 1
  fi
  export HTTPS_PROXY="http://127.0.0.1:$_port"
  export HTTP_PROXY="http://127.0.0.1:$_port"
fi

exec "$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" "$@"
WRAPPER
chmod +x "$PREFIX/bin/claude"
```

### Step 8 — Verify ✅

```bash
claude --version
# → 2.1.236 (Claude Code)
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

The `linux-arm64-musl` binary is dynamically linked against musl libc.
We extract the musl linker + libc from Alpine Linux and place them in
Termux's lib directory.

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

`patchelf` rewrites the header so the binary looks for the musl linker at
`$PREFIX/lib/ld-musl-aarch64.so.1` instead.

</details>

<details>
<summary><b>🎯 Why unset LD_PRELOAD?</b></summary>

<br>

Termux injects `libtermux-exec-ld-preload.so` (bionic helper) into every
process via `LD_PRELOAD`. The musl dynamic linker tries to load it and
crashes because it can't resolve bionic symbols:

```
Error relocating libtermux-exec-ld-preload.so: __register_atfork: symbol not found
```

The wrapper unsets `LD_PRELOAD` before executing the binary.

</details>

<details>
<summary><b>🌐 Why a DNS proxy (and not /etc/resolv.conf)?</b></summary>

<br>

The musl binary uses **c-ares** for DNS, which reads `/etc/resolv.conf`.
On Android that file doesn't exist and `/etc` is read-only, so without a
fix every API call hangs (`API error · Retrying`).

Options we tested and rejected:

| Approach | Result |
|---|---|
| Write `/etc/resolv.conf` | ❌ needs root (`/etc` read-only) |
| LD_PRELOAD shim to intercept `open()` | ❌ Bun inlines syscalls — not intercepted |
| `HTTPS_PROXY` pointing at a manual proxy | ❌ nothing listens (no root → can't bind :53) |
| proot with a fake rootfs | ❌ crashes child processes (SIGSEGV) |
| **dnsproxy.py CONNECT proxy** | ✅ **no root, no proot — works** |

The wrapper auto-starts `dnsproxy.py` on `127.0.0.1:8080` (configurable via
`CLAUDE_DNS_PROXY_PORT`), which resolves through Android's native resolver.
The proxy log lives at `$PREFIX/tmp/dnsproxy.log`.

</details>

---

## 🔄 **Updating**

```bash
# Re-run installer (idempotent — skips what's already done)
sh install.sh

# Force-update Claude Code to the latest version:
sh install.sh --update
```

---

## 🗑 **Uninstalling**

```bash
# Remove the wrapper + DNS proxy, then the package:
rm -f "$PREFIX/bin/claude"
rm -f "$PREFIX/bin/dnsproxy.py"
npm uninstall -g @anthropic-ai/claude-code
rm -f "$PREFIX/lib/ld-musl-aarch64.so.1"
rm -f "$PREFIX/lib/libc.musl-aarch64.so.1"
# Stop any running DNS proxy:
pkill -f dnsproxy.py
```

---

## 🐛 **Troubleshooting**

<details>
<summary><code>Error relocating libtermux-exec-ld-preload.so: __register_atfork: symbol not found</code></summary>

LD_PRELOAD conflict — re-run `sh install.sh` or manually create the wrapper
(see Step 7 above).

</details>

<details>
<summary><code>Error: claude native binary not installed</code></summary>

Postinstall didn't extract the binary. Re-run: `sh install.sh`

</details>

<details>
<summary><code>cannot execute: required file not found</code></summary>

Musl dynamic linker missing. Reinstall musl libs: `sh install.sh`

</details>

<details>
<summary><code>API error · Retrying</code> forever</summary>

DNS inside the musl binary — the wrapper usually fixes this automatically.
Check the proxy:

```bash
# Is dnsproxy running + did it see CONNECT requests?
tail -3 "$PREFIX/tmp/dnsproxy.log"
# → "dnsproxy: listening on 127.0.0.1:8080"
# → "CONNECT your-api-host:443"

# Not running? Start it manually and re-run claude:
setsid python3 "$PREFIX/bin/dnsproxy.py" 8080 >"$PREFIX/tmp/dnsproxy.log" 2>&1 &
HTTPS_PROXY=http://127.0.0.1:8080 claude
```

If you changed the port: `CLAUDE_DNS_PROXY_PORT=9090 claude`

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

---

## 📊 **Tested On**

| Device | Android | Termux | Node.js | Claude Code | Status |
|--------|---------|--------|---------|-------------|--------|
| aarch64 phone (KernelSU) | Android 14+ | Latest | v26.x | v2.1.236 | ✅ no-root |

---

## ⚠️ **Limitations**

- Binary is **~310 MB** — needs storage space
- Desktop GUI features won't work (expected on Termux)
- Your API endpoint may need `NODE_TLS_REJECT_UNAUTHORIZED=0` if it uses a
  non-standard TLS cert (the wrapper sets this automatically)
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