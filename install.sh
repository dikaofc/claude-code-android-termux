#!/usr/bin/env bash
# ============================================================================
# Claude Code — Android Termux Installer
# ============================================================================
# Automated installer & patch to run Claude Code on Android (Termux) aarch64.
#
# What this script does:
#   1. Detects Android/Termux environment
#   2. Installs required dependencies (node, npm, patchelf, curl)
#   3. Installs @anthropic-ai/claude-code via npm (--force to bypass platform)
#   4. Downloads musl dynamic linker + libc from Alpine Linux aarch64
#   5. Patches install.cjs and cli-wrapper.cjs to use musl binary on Android
#   6. Runs postinstall to extract the native binary
#   7. Patches the binary with patchelf (interpreter + RPATH)
#   8. Verifies installation
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dikaofc/claude-code-android-termux/main/install.sh | bash
#   OR
#   bash install.sh
#
# Re-run safe: This script is idempotent. You can run it again after updates.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MUSL_VERSION="1.2.5-r11"
MUSL_APK_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/musl-${MUSL_VERSION}.apk"
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
NODE_MODULES="${TERMUX_PREFIX}/lib/node_modules/@anthropic-ai/claude-code"
CC_LIB="${TERMUX_PREFIX}/lib"
TMPDIR_BASE="${TMPDIR:-/data/data/com.termux/files/home}"
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${RESET}  %s\n" "$*" >&2; exit 1; }

step() {
  printf "\n${BOLD}${CYAN}━━━ Step %s: %s ━━━${RESET}\n" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Step 0: Environment checks
# ---------------------------------------------------------------------------
step 0 "Checking environment"

# Must be Android/Termux
if [ "$(uname -o 2>/dev/null)" != "Android" ] && [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
  warn "This script is designed for Android Termux. Detected: $(uname -s -o 2>/dev/null)"
  warn "Proceeding anyway, but results may vary."
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  fail "This script requires aarch64/arm64 architecture. Detected: $ARCH"
fi
ok "Architecture: $ARCH"

# Check node
if ! command -v node &>/dev/null; then
  fail "Node.js not found. Install with: pkg install nodejs"
fi
NODE_VER="$(node -v)"
ok "Node.js: $NODE_VER"

# Check npm
if ! command -v npm &>/dev/null; then
  fail "npm not found. Install with: pkg install nodejs"
fi
NPM_VER="$(npm -v)"
ok "npm: $NPM_VER"

# ---------------------------------------------------------------------------
# Step 1: Install dependencies
# ---------------------------------------------------------------------------
step 1 "Installing dependencies"

DEPS_NEEDED=()
command -v curl    &>/dev/null || DEPS_NEEDED+=("curl")
command -v patchelf &>/dev/null || DEPS_NEEDED+=("patchelf")

if [ ${#DEPS_NEEDED[@]} -gt 0 ]; then
  info "Installing missing packages: ${DEPS_NEEDED[*]}"
  pkg install -y "${DEPS_NEEDED[@]}" 2>/dev/null || apt install -y "${DEPS_NEEDED[@]}" 2>/dev/null || {
    warn "Could not install via pkg/apt. Trying manual install..."
    for dep in "${DEPS_NEEDED[@]}"; do
      case "$dep" in
        curl)    pkg install -y curl 2>/dev/null ;;
        patchelf) pkg install -y patchelf 2>/dev/null ;;
      esac
    done
  }
fi

# Verify patchelf
if ! command -v patchelf &>/dev/null; then
  fail "patchelf is required but could not be installed."
fi
ok "All dependencies available"

# ---------------------------------------------------------------------------
# Step 2: Install Claude Code via npm
# ---------------------------------------------------------------------------
step 2 "Installing Claude Code (npm)"

# Check if already installed and what version
CC_VERSION=""
if command -v claude &>/dev/null; then
  CC_VERSION="$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
fi

if [ -n "$CC_VERSION" ]; then
  info "Claude Code v${CC_VERSION} is already installed."
  info "To upgrade, run: npm install -g @anthropic-ai/claude-code@latest"
fi

# Check if the native binary is actually working
BINARY_OK=false
if command -v claude &>/dev/null; then
  if claude --version &>/dev/null; then
    BINARY_OK=true
    OUTPUT="$(claude --version 2>&1)"
    if echo "$OUTPUT" | grep -q "native binary not installed"; then
      BINARY_OK=false
    fi
  fi
fi

if [ "$BINARY_OK" = true ]; then
  ok "Claude Code is already working: $(claude --version 2>&1)"
  ok "Nothing more to do!"
  exit 0
fi

# Install or reinstall Claude Code
if [ ! -d "$NODE_MODULES" ]; then
  info "Claude Code not found. Installing..."
  npm install -g @anthropic-ai/claude-code --force --ignore-scripts 2>&1 | tail -3
else
  info "Claude Code package found but binary not working. Will patch..."
fi

# Verify package is present
if [ ! -d "$NODE_MODULES" ]; then
  fail "Claude Code package not found at $NODE_MODULES after install."
fi
ok "Claude Code package is present"

# ---------------------------------------------------------------------------
# Step 3: Patch install.cjs and cli-wrapper.cjs
# ---------------------------------------------------------------------------
step 3 "Patching platform detection scripts"

INSTALL_CJS="${NODE_MODULES}/install.cjs"
CLI_WRAPPER="${NODE_MODULES}/cli-wrapper.cjs"

for FILE in "$INSTALL_CJS" "$CLI_WRAPPER"; do
  if [ ! -f "$FILE" ]; then
    fail "Required file not found: $FILE"
  fi

  # Check if already patched
  if grep -q "linux-\${cpu}-musl" "$FILE" 2>/dev/null || grep -q "linux-.*cpu.*-musl" "$FILE" 2>/dev/null; then
    ok "$(basename "$FILE") is already patched"
    continue
  fi

  # Patch: change android platform mapping from -android to -musl
  # Original line:
  #   return 'linux-' + cpu + '-android'
  # Patched to:
  #   return 'linux-' + cpu + '-musl'
  #
  # We use sed to do the replacement. The pattern matches the exact line in
  # getPlatformKey() where android is handled.
  if grep -q "linux-.*-android" "$FILE"; then
    # Create backup
    cp "$FILE" "${FILE}.bak"

    # Replace: return 'linux-' + cpu + '-android'
    # With:    return 'linux-' + cpu + '-musl'
    # Also add a comment explaining why
    sed -i \
      -e "/platform === 'android'/,/return 'linux-/{s/return 'linux-' + cpu + '-android'/\/\/ Android (Termux) has no dedicated binary; use musl build\n    return 'linux-' + cpu + '-musl'/}" \
      "$FILE"

    # Verify the patch was applied
    if grep -q "'-musl'" "$FILE" && grep -q "android" "$FILE"; then
      ok "$(basename "$FILE") patched successfully"
    else
      warn "sed patch may not have applied cleanly to $(basename "$FILE"). Trying alternative..."
      # Alternative: direct string replacement
      sed -i "s/return 'linux-' + cpu + '-android'/\/\/ Android (Termux): use musl binary instead\n    return 'linux-' + cpu + '-musl'/" "$FILE"
      if grep -q "'-musl'" "$FILE"; then
        ok "$(basename "$FILE") patched (alternative method)"
      else
        warn "Could not patch $(basename "$FILE"). Manual intervention may be needed."
      fi
    fi
  else
    ok "$(basename "$FILE") does not contain android mapping (may already be updated upstream)"
  fi
done

# ---------------------------------------------------------------------------
# Step 4: Download and install musl dynamic linker + libc
# ---------------------------------------------------------------------------
step 4 "Installing musl runtime libraries"

MUSL_LD="${CC_LIB}/ld-musl-aarch64.so.1"
MUSL_LIBC="${CC_LIB}/libc.musl-aarch64.so.1"

if [ -f "$MUSL_LD" ] && [ -f "$MUSL_LIBC" ]; then
  ok "musl libraries already present"
else
  info "Downloading musl ${MUSL_VERSION} from Alpine Linux aarch64..."
  MUSL_TMP="${TMPDIR_BASE}/.musl-install-$$"
  mkdir -p "$MUSL_TMP"

  # Download the APK package
  curl -fSL -o "${MUSL_TMP}/musl.apk" "$MUSL_APK_URL" 2>&1 || {
    fail "Failed to download musl package from $MUSL_APK_URL"
  }

  # Extract (APK is just a gzipped tar)
  tar xzf "${MUSL_TMP}/musl.apk" -C "$MUSL_TMP" 2>/dev/null || {
    # Some tar versions don't handle APK headers; extract just what we need
    cd "$MUSL_TMP"
    gunzip -f musl.apk 2>/dev/null || true
    tar xf musl.apk.tar -C "$MUSL_TMP" 2>/dev/null || tar xf "${MUSL_TMP}/musl.apk" --wildcards 'lib/*musl*' -C "$MUSL_TMP" 2>/dev/null || true
    cd -
  }

  # Find and copy the libraries
  LD_SRC="$(find "$MUSL_TMP" -name 'ld-musl-aarch64.so*' -type f -o -name 'ld-musl-aarch64.so*' -type l 2>/dev/null | head -1)"
  LIBC_SRC="$(find "$MUSL_TMP" -name 'libc.musl-aarch64.so*' -type f -o -name 'libc.musl-aarch64.so*' -type l 2>/dev/null | head -1)"

  if [ -z "$LD_SRC" ] || [ -z "$LIBC_SRC" ]; then
    # Fallback: the musl package contains ld-musl-aarch64.so.1 which is
    # hardlinked to libc.musl-aarch64.so.1 (same inode, same content).
    # If extraction only got one, copy it for both.
    FOUND="$(find "$MUSL_TMP" -name '*musl*aarch64*' -type f 2>/dev/null | head -1)"
    if [ -z "$FOUND" ]; then
      fail "Could not find musl libraries in downloaded package."
    fi
    LD_SRC="$FOUND"
    LIBC_SRC="$FOUND"
  fi

  cp "$LD_SRC" "$MUSL_LD" 2>/dev/null || fail "Cannot write $MUSL_LD — check Termux permissions"
  cp "$LIBC_SRC" "$MUSL_LIBC" 2>/dev/null || fail "Cannot write $MUSL_LIBC — check Termux permissions"
  chmod 755 "$MUSL_LD" "$MUSL_LIBC"

  # Cleanup
  rm -rf "$MUSL_TMP"

  ok "musl runtime installed to $CC_LIB/"
fi

# ---------------------------------------------------------------------------
# Step 5: Run postinstall to place the native binary
# ---------------------------------------------------------------------------
step 5 "Running Claude Code postinstall"

cd "$NODE_MODULES"
node install.cjs 2>&1 || warn "Postinstall exited with warnings (non-fatal)"

BINARY="${NODE_MODULES}/bin/claude.exe"
if [ ! -f "$BINARY" ]; then
  fail "Binary not found at $BINARY after postinstall."
fi

# Check if it's the stub or the real binary
FILE_SIZE=$(wc -c < "$BINARY" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 1000 ]; then
  fail "Binary appears to be the error stub (${FILE_SIZE} bytes). Postinstall may have failed."
fi

ok "Native binary present ($(numfmt --to=iec-i --suffix=B "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes"))"

# ---------------------------------------------------------------------------
# Step 6: Patch binary with patchelf (interpreter + RPATH)
# ---------------------------------------------------------------------------
step 6 "Patching binary with patchelf"

INTERP_TARGET="${CC_LIB}/ld-musl-aarch64.so.1"

# Check if already patched
CURRENT_INTERP="$(readelf -l "$BINARY" 2>/dev/null | grep INTERP | awk '{print $NF}' || true)"
if echo "$CURRENT_INTERP" | grep -q "ld-musl"; then
  ok "Binary interpreter already points to musl linker"
else
  info "Setting interpreter to $INTERP_TARGET"
  patchelf --set-interpreter "$INTERP_TARGET" "$BINARY" 2>&1 || fail "patchelf --set-interpreter failed"
  ok "Interpreter patched"
fi

CURRENT_RPATH="$(readelf -d "$BINARY" 2>/dev/null | grep -oP 'Library runpath: \[\K[^\]]+' || true)"
if [ "$CURRENT_RPATH" = "$CC_LIB" ]; then
  ok "RUNPATH already set correctly"
else
  info "Setting RUNPATH to $CC_LIB"
  patchelf --set-rpath "$CC_LIB" "$BINARY" 2>&1 || fail "patchelf --set-rpath failed"
  ok "RUNPATH patched"
fi

# ---------------------------------------------------------------------------
# Step 7: Create/update the `claude` wrapper script
# ---------------------------------------------------------------------------
step 7 "Setting up claude command"

# npm creates the `claude` symlink/script during install. Make sure it points
# to the right thing.
CLAUDE_BIN="${TERMUX_PREFIX}/bin/claude"

# Check if `claude` works already
if claude --version &>/dev/null 2>&1; then
  ok "claude command is already working"
else
  # Create a wrapper if the npm one is broken
  if [ -f "$CLAUDE_BIN" ] || [ -L "$CLAUDE_BIN" ]; then
    info "Rewriting $CLAUDE_BIN wrapper..."
  fi

  cat > "$CLAUDE_BIN" << 'WRAPPER'
#!/usr/bin/env bash
exec "$(dirname "$0")/../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" "$@"
WRAPPER
  chmod +x "$CLAUDE_BIN"
  ok "Wrapper script created at $CLAUDE_BIN"
fi

# ---------------------------------------------------------------------------
# Step 8: Verify
# ---------------------------------------------------------------------------
step 8 "Verifying installation"

printf "\n"

# Test 1: version check
if OUTPUT="$(claude --version 2>&1)"; then
  ok "claude --version → $OUTPUT"
else
  fail "claude --version failed with: $OUTPUT"
fi

# Test 2: binary is ELF
FILE_TYPE="$(file "$BINARY" 2>/dev/null)"
if echo "$FILE_TYPE" | grep -q "ELF.*aarch64"; then
  ok "Binary is ELF aarch64"
else
  warn "Binary file type unexpected: $FILE_TYPE"
fi

# Test 3: musl linker resolved
if echo "$FILE_TYPE" | grep -q "musl"; then
  ok "Linked against musl"
else
  warn "Binary may not be linked against musl"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf "\n${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "${BOLD}${GREEN}  ✓ Claude Code is installed and working on Android Termux!${RESET}\n"
printf "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "\n"
printf "  ${BOLD}Version:${RESET}    $(claude --version 2>&1)\n"
printf "  ${BOLD}Binary:${RESET}     $BINARY\n"
printf "  ${BOLD}musl libs:${RESET}  $CC_LIB/ld-musl-aarch64.so.1\n"
printf "  ${BOLD}Command:${RESET}    claude\n"
printf "\n"
printf "  ${BOLD}Usage:${RESET}\n"
printf "    claude                    # Start interactive mode\n"
printf "    claude \"your prompt\"       # Single prompt\n"
printf "    claude --help             # Show all options\n"
printf "\n"
printf "  ${BOLD}Re-run installer:${RESET}\n"
printf "    bash install.sh\n"
printf "\n"
printf "  ${BOLD}Uninstall:${RESET}\n"
printf "    bash <(curl -fsSL .../uninstall.sh)\n"
printf "\n"
