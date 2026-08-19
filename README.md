# Claude Code on Android Termux

Automatic installer & patch to run [Claude Code](https://github.com/anthropics/claude-code) on Android via [Termux](https://termux.dev).

## The Problem

Claude Code does not officially publish an Android binary. When installed on Termux:

- `process.platform` returns `"android"` (not `"linux"`)
- The install script maps this to `linux-arm64-android` — a package that **doesn't exist** in `optionalDependencies`
- npm also refuses to download the `linux-arm64-musl` package because the OS is `android`, not `linux`
- Result: you get the error stub instead of the real ~250 MB native binary

```
Error: claude native binary not installed.
```

## The Solution

This script:

1. Installs Claude Code via npm (`--force` to bypass platform checks)
2. Downloads the **musl** aarch64 binary (statically-linked libc, works on Android)
3. Downloads `ld-musl-aarch64.so.1` + `libc.musl-aarch64.so.1` from Alpine Linux
4. Patches the install/wrapper scripts to map Android → musl
5. Patches the binary with `patchelf` (interpreter + RPATH)
6. Verifies everything works

---

## Quick Install (One Command)

```bash
curl -fsSL https://raw.githubusercontent.com/dikaofc/claude-code-android-termux/main/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/dikaofc/claude-code-android-termux.git
cd claude-code-android-termux
bash install.sh
```

## Manual Install (Step by Step)

If you prefer to understand each step or the automatic script fails:

### Prerequisites

```bash
# Make sure you have these
pkg update && pkg upgrade
pkg install nodejs npm curl git
```

**Node.js ≥ 22.0.0 is required** by Claude Code.

### Step 1: Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code --force --ignore-scripts
```

The `--force` flag is needed because npm sees `os: android` instead of `os: linux`.
The `--ignore-scripts` flag prevents the postinstall from running (it would fail at this point).

### Step 2: Patch the platform detection

The install script and CLI wrapper both map `android` → `linux-arm64-android`, but that
package doesn't exist. We remap to `linux-arm64-musl`.

**File: `$PREFIX/lib/node_modules/@anthropic-ai/claude-code/install.cjs`**

Find this block in `getPlatformKey()`:

```javascript
if (platform === 'android') {
    return 'linux-' + cpu + '-android'
}
```

Replace with:

```javascript
if (platform === 'android') {
    // Android (Termux) has no dedicated binary; use musl build
    return 'linux-' + cpu + '-musl'
}
```

**File: `$PREFIX/lib/node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs`**

Same replacement as above.

### Step 3: Install musl runtime libraries

Claude Code's aarch64 binary is dynamically linked against musl libc. Termux uses
Android's bionic libc, so we need to provide the musl linker + libc manually.

```bash
# Download musl from Alpine Linux
curl -fSL -o /tmp/musl.apk \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/musl-1.2.5-r11.apk"

# Extract
mkdir -p /tmp/musl-extract
tar xzf /tmp/musl.apk -C /tmp/musl-extract 2>/dev/null

# Copy to Termux lib directory
cp /tmp/musl-extract/lib/ld-musl-aarch64.so.1  "$PREFIX/lib/"
cp /tmp/musl-extract/lib/libc.musl-aarch64.so.1 "$PREFIX/lib/"
chmod 755 "$PREFIX/lib"/ld-musl-aarch64.so.1 "$PREFIX/lib"/libc.musl-aarch64.so.1

# Cleanup
rm -rf /tmp/musl.apk /tmp/musl-extract
```

### Step 4: Run postinstall

```bash
cd "$PREFIX/lib/node_modules/@anthropic-ai/claude-code"
node install.cjs
```

This extracts the native binary from the musl package into `bin/claude.exe`.

### Step 5: Patch the binary with patchelf

The binary expects the musl linker at `/lib/ld-musl-aarch64.so.1`, but `/lib` is
read-only on Android. We use `patchelf` to redirect it to Termux's lib directory.

```bash
# Install patchelf if needed
pkg install patchelf

BINARY="$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"

# Set interpreter (dynamic linker path)
patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" "$BINARY"

# Set RUNPATH so libc.musl-aarch64.so.1 is found
patchelf --set-rpath "$PREFIX/lib" "$BINARY"
```

### Step 6: Verify

```bash
claude --version
# Expected output: 2.1.220 (Claude Code)
```

---

## How It Works

### Why musl?

| C Library | Available on Termux | Works with Claude Code binary |
|-----------|---------------------|-------------------------------|
| bionic (Android) | ✅ native | ❌ different ABI |
| glibc | ❌ not available | ❌ not available |
| **musl** | ❌ not installed | ✅ **Yes** — binary is compiled against musl |

The Claude Code aarch64 binary (`linux-arm64-musl`) is compiled against musl libc.
Since musl is designed to be lightweight and portable, we can extract the musl dynamic
linker and libc from Alpine Linux and provide them alongside the binary.

### Why `patchelf`?

The binary's ELF header says:

```
INTERP: /lib/ld-musl-aarch64.so.1
```

On a normal Linux system, `/lib/ld-musl-aarch64.so.1` exists. On Android/Termux:

- `/lib` is a read-only symlink to `/system/lib`
- The musl linker doesn't exist there at all

`patchelf` rewrites the ELF header so the binary looks for the musl linker at
`$PREFIX/lib/ld-musl-aarch64.so.1` instead, where we placed it.

### Why `--force` for npm?

npm checks `process.platform` and `process.arch` against the package's `os` and `cpu`
fields. Since Claude Code's musl package declares `"os": "linux"` and we're on
`"os": "android"`, npm refuses to install it. `--force` overrides this check.

---

## Updating

When a new version of Claude Code is released, reinstall:

```bash
# Option 1: Re-run this script (handles everything automatically)
bash install.sh

# Option 2: Manual update
npm install -g @anthropic-ai/claude-code@latest --force --ignore-scripts
bash install.sh
```

The script is **idempotent** — it detects if things are already patched and skips them.

---

## Uninstalling

```bash
# Option 1: Use the uninstall script
bash uninstall.sh

# Option 2: Manual
npm uninstall -g @anthropic-ai/claude-code
rm -f "$PREFIX/lib/ld-musl-aarch64.so.1"
rm -f "$PREFIX/lib/libc.musl-aarch64.so.1"
```

---

## Troubleshooting

### `claude: command not found`

```bash
# Make sure $PREFIX/bin is in your PATH
echo 'export PATH="/data/data/com.termux/files/usr/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### `cannot execute: required file not found`

The musl dynamic linker is missing or at the wrong path.

```bash
# Reinstall musl libs
bash install.sh
```

### `Error relocating ... libtermux-exec-ld-preload.so: __register_atfork: symbol not found`

Termux injects `libtermux-exec-ld-preload.so` (a bionic helper) into the process environment. The musl dynamic linker can't resolve bionic symbols. The fix is a wrapper script that runs `unset LD_PRELOAD` before launching the binary. The `install.sh` does this automatically. If you're fixing manually:

```bash
cat > /data/data/com.termux/files/usr/bin/claude << 'EOF'
#!/bin/sh
unset LD_PRELOAD
exec /data/data/com.termux/files/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe "$@"
EOF
chmod +x /data/data/com.termux/files/usr/bin/claude
```


### `Error: claude native binary not installed`

The postinstall didn't place the real binary. The `bin/claude.exe` is still the error stub.

```bash
# Re-run the installer
bash install.sh
```

### `npm ERR! EBADPLATFORM`

npm is rejecting the package due to platform mismatch. This is expected — use `--force`.

### `patchelf: command not found`

```bash
pkg install patchelf
```

### Node.js version too old

Claude Code requires Node.js ≥ 22.0.0.

```bash
pkg install nodejs
node -v  # Should show v22.x or higher
```

### Permission denied

Make sure you're not running as root in a chroot. Termux apps run as a regular user
in their own namespace.

---

## Tested On

| Device | Android | Termux | Node.js | Status |
|--------|---------|--------|---------|--------|
| aarch64 phone | Android 14 | Latest | v26.4.0 | ✅ Working |

## Limitations

- The binary is **~250 MB** — make sure you have enough storage
- Some Claude Code features that depend on desktop GUI will not work (expected on headless/termux)
- When Claude Code publishes an official Android binary, this patch will no longer be needed

## Credits

- [Claude Code](https://github.com/anthropics/claude-code) by Anthropic
- [Termux](https://termux.dev) — Android terminal emulator
- [Alpine Linux](https://alpinelinux.org) — musl libc source

## License

MIT — use freely, no warranty.
