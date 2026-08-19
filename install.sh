#!/usr/bin/env bash
# ============================================================================
# Claude Code for Android Termux - Installer
# ============================================================================
# Repository: https://github.com/dikaofc/claude-code-android-termux
# License: MIT
#
# This script automates installing Claude Code on Android Termux (ARM64).
# It handles: npm install, platform patching, musl runtime, ELF patching,
# DNS resolution (proot), and LD_PRELOAD stripping.
#
# Usage:
#   bash install.sh          # Install Claude Code
#   bash install.sh --update # Update to latest version
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Script directory (for local install)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Version tracking
CURRENT_VERSION=""
LATEST_VERSION=""
CLAUDE_DIR=""
BINARY_PATH=""
WRAPPER_PATH=""

# ============================================================================
# Utility Functions
# ============================================================================

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

step() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━ Step $1: $2 ━━━${NC}"
}

banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
    ╔══════════════════════════════════════════════════════╗
    ║         Claude Code · Android Termux Installer       ║
    ║            Automated ARM64 + musl Setup              ║
    ╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ============================================================================
# Phase 1: Environment Checks
# ============================================================================

check_android() {
    step "1/7" "Checking environment"

    # Check Android/Termux
    if [ "$(uname -o 2>/dev/null)" != "Android" ]; then
        error "Not running on Android. This installer is for Termux only."
    fi
    success "Android/Termux detected"

    # Check architecture
    local arch
    arch="$(uname -m)"
    if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then
        error "ARM64 (aarch64) required. Detected: $arch"
    fi
    success "Architecture: $arch"

    # Check Node.js
    if ! command -v node &>/dev/null; then
        warn "Node.js not found. Installing..."
        pkg install -y nodejs
    fi

    local node_version
    node_version="$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)"
    if [ -z "$node_version" ] || [ "$node_version" -lt 22 ] 2>/dev/null; then
        warn "Node.js >= 22 required (current: v$(node -v 2>/dev/null || echo 'not found'))"
        warn "Updating Node.js..."
        pkg install -y nodejs
    fi
    success "Node.js: $(node -v)"
    success "npm: $(npm -v)"

    # Check for Claude Code
    CLAUDE_DIR="$(npm root -g 2>/dev/null)/@anthropic-ai/claude-code"
    if [ -d "$CLAUDE_DIR" ]; then
        CURRENT_VERSION="$(node -e "console.log(require('$CLAUDE_DIR/package.json').version)" 2>/dev/null || echo "")"
        if [ -n "$CURRENT_VERSION" ]; then
            info "Claude Code v${CURRENT_VERSION} found"
        fi
    fi
}

install_dependencies() {
    step "2/7" "Installing dependencies"

    local deps_needed=()

    # curl - for downloading musl
    if ! command -v curl &>/dev/null; then
        deps_needed+=("curl")
    fi

    # patchelf - for ELF binary patching
    if ! command -v patchelf &>/dev/null; then
        deps_needed+=("patchelf")
    fi

    # proot - for DNS resolution (musl can't read Android's resolv.conf)
    if ! command -v proot &>/dev/null; then
        deps_needed+=("proot")
    fi

    if [ ${#deps_needed[@]} -gt 0 ]; then
        info "Installing: ${deps_needed[*]}"
        pkg install -y "${deps_needed[@]}"
        success "Dependencies installed"
    else
        success "All dependencies already installed"
    fi
}

# ============================================================================
# Phase 2: Install / Update Claude Code
# ============================================================================

install_claude_code() {
    step "3/7" "Installing Claude Code"

    # Check if already working
    if [ -n "$CURRENT_VERSION" ]; then
        # Verify the binary actually works
        if timeout 10 "$BINARY_PATH" --version &>/dev/null 2>&1; then
            success "Claude Code v${CURRENT_VERSION} is already installed and working"
            return 0
        fi
        warn "Claude Code exists but binary not working, reinstalling..."
    fi

    # Install with --force to bypass platform check
    info "Installing via npm (this may take a minute)..."
    if npm install -g @anthropic-ai/claude-code --force 2>&1 | tail -5; then
        CLAUDE_DIR="$(npm root -g)/@anthropic-ai/claude-code"
        CURRENT_VERSION="$(node -e "console.log(require('$CLAUDE_DIR/package.json').version)" 2>/dev/null || echo "")"
        success "Claude Code v${CURRENT_VERSION} installed"
    else
        error "npm install failed"
    fi

    # Re-patch after npm install (it may have overwritten patched files)
    patch_platform_mapping

    # Check for Android platform issue
    if [ ! -f "$CLAUDE_DIR/bin/claude.exe" ] || [ "$(stat -c%s "$CLAUDE_DIR/bin/claude.exe" 2>/dev/null || echo 0)" -lt 10000 ]; then
        warn "Platform mismatch detected - will patch in next step"
    fi
}

# ============================================================================
# Phase 3: Patch Platform Mapping
# ============================================================================

patch_platform_mapping() {
    step "4/7" "Patching platform mapping (Android → musl)"

    local patched=0

    # Patch install.cjs — replace 'return linux- + cpu + -android' with musl
    if [ -f "$CLAUDE_DIR/install.cjs" ]; then
        if grep -q "linux-' + cpu + '-android" "$CLAUDE_DIR/install.cjs" 2>/dev/null; then
            info "Patching install.cjs..."
            sed -i "s/return 'linux-' + cpu + '-android'/return 'linux-' + cpu + '-musl'/g" "$CLAUDE_DIR/install.cjs"
            patched=$((patched + 1))
            success "install.cjs patched"
        else
            success "install.cjs already patched"
        fi
    fi

    # Patch cli-wrapper.cjs — same pattern
    if [ -f "$CLAUDE_DIR/cli-wrapper.cjs" ]; then
        if grep -q "linux-' + cpu + '-android" "$CLAUDE_DIR/cli-wrapper.cjs" 2>/dev/null; then
            info "Patching cli-wrapper.cjs..."
            sed -i "s/return 'linux-' + cpu + '-android'/return 'linux-' + cpu + '-musl'/g" "$CLAUDE_DIR/cli-wrapper.cjs"
            patched=$((patched + 1))
            success "cli-wrapper.cjs patched"
        else
            success "cli-wrapper.cjs already patched"
        fi
    fi

    if [ $patched -eq 0 ]; then
        success "Platform mapping already correct"
    fi
}

# ============================================================================
# Phase 4: Install musl Binary
# ============================================================================

install_musl_binary() {
    step "5/7" "Installing musl binary"

    BINARY_PATH="$CLAUDE_DIR/bin/claude.exe"
    local bin_size
    bin_size=$(stat -c%s "$BINARY_PATH" 2>/dev/null || echo 0)

    # Check if real binary is already in place (musl binary is ~265MB)
    if [ "$bin_size" -gt 100000000 ] 2>/dev/null; then
        # Verify it's actually a musl binary
        if readelf -d "$BINARY_PATH" 2>/dev/null | grep -q "musl"; then
            success "musl binary already in place ($(numfmt --to=iec $bin_size))"
            return 0
        fi
    fi

    # Need to install the musl binary
    info "Downloading musl binary..."

    # Install the musl package with --force (bypasses platform check)
    if npm install -g @anthropic-ai/claude-code-linux-arm64-musl@"$CURRENT_VERSION" --force 2>&1 | tail -5; then
        success "musl package downloaded"
    else
        error "Failed to download musl binary"
    fi

    # Run postinstall to copy binary
    info "Running postinstall..."
    cd "$CLAUDE_DIR" || error "Cannot access Claude Code directory"
    node install.cjs 2>&1 | tail -3

    # Verify
    bin_size=$(stat -c%s "$BINARY_PATH" 2>/dev/null || echo 0)
    if [ "$bin_size" -lt 100000000 ] 2>/dev/null; then
        error "Binary installation failed (size: $bin_size bytes)"
    fi
    success "Binary installed ($(numfmt --to=iec $bin_size))"
}

# ============================================================================
# Phase 5: Download musl Runtime + patchelf
# ============================================================================

patch_musl_runtime() {
    step "6/7" "Patching musl runtime"

    BINARY_PATH="$CLAUDE_DIR/bin/claude.exe"

    # Check if already patched
    local interpreter
    interpreter="$(readelf -l "$BINARY_PATH" 2>/dev/null | grep "interpreter" | sed 's/.*: //' | sed 's/].*//')"
    if echo "$interpreter" | grep -q "com.termux"; then
        success "Binary already patched with Termux paths"
        return 0
    fi

    local MUSL_LIB="/data/data/com.termux/files/usr/lib"

    # Download musl from Alpine Linux if not present
    if [ ! -f "$MUSL_LIB/ld-musl-aarch64.so.1" ]; then
        info "Downloading musl runtime from Alpine Linux..."

        local MUSL_VERSION="3.21.0-r0"
        local MUSL_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/musl-${MUSL_VERSION}.apk"

        # Download to /tmp (writable on all Termux installs)
        if ! curl -fsSL -o /tmp/musl.apk "$MUSL_URL" 2>/dev/null; then
            # Try alternative mirror
            MUSL_URL="https://uk.alpinelinux.org/alpine/v3.21/main/aarch64/musl-${MUSL_VERSION}.apk"
            curl -fsSL -o /tmp/musl.apk "$MUSL_URL" 2>/dev/null || error "Failed to download musl runtime"
        fi

        # Extract
        mkdir -p /tmp/musl-extract
        tar xzf /tmp/musl.apk -C /tmp/musl-extract 2>/dev/null || tar xf /tmp/musl.apk -C /tmp/musl-extract 2>/dev/null

        # Copy libraries
        cp /tmp/musl-extract/lib/ld-musl-aarch64.so.1 "$MUSL_LIB/"
        cp /tmp/musl-extract/lib/libc.musl-aarch64.so.1 "$MUSL_LIB/"

        # Cleanup
        rm -rf /tmp/musl.apk /tmp/musl-extract

        success "musl runtime downloaded"
    else
        success "musl runtime already present"
    fi

    # Patch binary with patchelf
    info "Patching binary with patchelf..."
    patchelf --set-interpreter "$MUSL_LIB/ld-musl-aarch64.so.1" "$BINARY_PATH"
    patchelf --set-rpath "$MUSL_LIB" "$BINARY_PATH"
    success "Binary patched successfully"

    # Verify
    interpreter="$(readelf -l "$BINARY_PATH" 2>/dev/null | grep "interpreter" | sed 's/.*: //' | sed 's/].*//')"
    if echo "$interpreter" | grep -q "com.termux"; then
        success "Patch verified: interpreter → $interpreter"
    else
        error "Patch verification failed"
    fi
}

# ============================================================================
# Phase 6: Create Wrapper + DNS Fix
# ============================================================================

setup_wrapper() {
    step "7/7" "Creating wrapper and DNS fix"

    BINARY_PATH="$CLAUDE_DIR/bin/claude.exe"
    local MUSL_LIB="/data/data/com.termux/files/usr/lib"
    local USR_BIN="/data/data/com.termux/files/usr/bin"

    # Ensure proot rootfs exists with resolv.conf + CA certs
    local PROOT_ROOT="$HOME/.claude-proot"
    mkdir -p "$PROOT_ROOT/etc/ssl/certs" "$PROOT_ROOT/usr/local/share/ca-certificates" "$PROOT_ROOT/etc/pki/tls/certs" "$PROOT_ROOT/usr/local/etc/openssl" "$PROOT_ROOT/tmp"
    chmod 1777 "$PROOT_ROOT/tmp" 2>/dev/null || true

    # DNS resolution
    if [ ! -f "$PROOT_ROOT/etc/resolv.conf" ]; then
        cat > "$PROOT_ROOT/etc/resolv.conf" << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2606:4700:4700::1111
RESOLV
        success "Created proot resolv.conf for DNS"
    else
        success "proot resolv.conf already exists"
    fi

    # CA certificates (musl's Bun needs these for SSL)
    if [ ! -f "$PROOT_ROOT/etc/ssl/certs/ca-certificates.crt" ]; then
        info "Downloading CA certificates..."
        if curl -fsSL -o /tmp/cacert.pem https://curl.se/ca/cacert.pem 2>/dev/null; then
            cp /tmp/cacert.pem "$PROOT_ROOT/etc/ssl/certs/ca-certificates.crt"
            cp /tmp/cacert.pem "$PROOT_ROOT/usr/local/share/ca-certificates/ca-certificates.crt"
            cp /tmp/cacert.pem "$PROOT_ROOT/etc/pki/tls/certs/ca-bundle.crt"
            cp /tmp/cacert.pem "$PROOT_ROOT/etc/pki/tls/cert.pem"
            cp /tmp/cacert.pem "$PROOT_ROOT/usr/local/etc/openssl/cert.pem"
            cp /tmp/cacert.pem "$PROOT_ROOT/etc/ssl/cert.pem"
            cp /tmp/cacert.pem "$PROOT_ROOT/etc/ssl/ca-bundle.pem"
            rm -f /tmp/cacert.pem
            success "CA certificates installed"
        else
            warn "Failed to download CA certificates (SSL may fail)"
        fi
    else
        success "CA certificates already installed"
    fi

    # Remove npm symlink before creating wrapper script
    if [ -L "$USR_BIN/claude" ]; then
        rm -f "$USR_BIN/claude"
    fi

    # Create wrapper script (this is what `claude` actually runs)
    # Use a quoted heredoc to avoid escaping issues, then sed-replace placeholders
    cat > "$USR_BIN/claude" << 'WRAPPER'
#!/bin/sh
# Claude Code wrapper for Android Termux
# Fixes: DNS resolution (musl reads /etc/resolv.conf which doesn't exist on Android)
#        LD_PRELOAD (bionic exec helper incompatible with musl)

unset LD_PRELOAD

# Ensure ANTHROPIC env vars are set from settings.json if not in environment
if [ -z "$ANTHROPIC_API_KEY" ]; then
  if [ -f "$HOME/.claude/settings.json" ]; then
    _key=$(grep -o '"ANTHROPIC_API_KEY"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
    [ -n "$_key" ] && export ANTHROPIC_API_KEY="$_key"
  fi
fi
if [ -z "$ANTHROPIC_BASE_URL" ]; then
  if [ -f "$HOME/.claude/settings.json" ]; then
    _url=$(grep -o '"ANTHROPIC_BASE_URL"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
    [ -n "$_url" ] && export ANTHROPIC_BASE_URL="$_url"
  fi
fi
if [ -z "$ANTHROPIC_MODEL" ]; then
  if [ -f "$HOME/.claude/settings.json" ]; then
    _model=$(grep -o '"ANTHROPIC_MODEL"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
    [ -n "$_model" ] && export ANTHROPIC_MODEL="$_model"
  fi
fi
if [ -z "$ANTHROPIC_SMALL_FAST_MODEL" ]; then
  if [ -f "$HOME/.claude/settings.json" ]; then
    _sfm=$(grep -o '"ANTHROPIC_SMALL_FAST_MODEL"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
    [ -n "$_sfm" ] && export ANTHROPIC_SMALL_FAST_MODEL="$_sfm"
  fi
fi
export NODE_TLS_REJECT_UNAUTHORIZED="0"

# If proot rootfs doesn't exist, fall back to direct execution
if [ ! -d "@@PROOT_ROOT@@/etc" ]; then
  exec "@@BINARY_PATH@@" "$@"
fi

# Use proot to provide /etc/resolv.conf for DNS resolution
exec proot \
  -r "@@PROOT_ROOT@@" \
  -b /dev \
  -b /proc \
  -b /sys \
  -b "@@USR_BIN@@:/usr/bin" \
  -b "@@MUSL_LIB@@:/usr/lib" \
  -b "@@MUSL_LIB@@/../tmp" \
  -b /tmp \
  -w "$HOME" \
  --link2symlink \
  "@@BINARY_PATH@@" "$@"
WRAPPER

    # Replace placeholders with actual paths
    sed -i "s|@@PROOT_ROOT@@|$PROOT_ROOT|g" "$USR_BIN/claude"
    sed -i "s|@@BINARY_PATH@@|$BINARY_PATH|g" "$USR_BIN/claude"
    sed -i "s|@@MUSL_LIB@@|$MUSL_LIB|g" "$USR_BIN/claude"
    sed -i "s|@@USR_BIN@@|$USR_BIN|g" "$USR_BIN/claude"

    chmod +x "$USR_BIN/claude"

    success "Wrapper script created at $USR_BIN/claude"
}

# ============================================================================
# Phase 7: Verify
# ============================================================================

verify_installation() {
    echo ""
    echo -e "${GREEN}${BOLD}━━━ Verifying Installation ━━━${NC}"

    # Check wrapper exists and is executable
    if [ ! -x "$WRAPPER_PATH" ]; then
        error "Wrapper script not found or not executable"
    fi

    # Check binary exists
    local bin_size
    bin_size=$(stat -c%s "$BINARY_PATH" 2>/dev/null || echo 0)
    if [ "$bin_size" -lt 100000000 ] 2>/dev/null; then
        error "Binary not properly installed"
    fi

    # Test binary execution
    info "Testing binary..."
    local version_output
    if version_output=$(timeout 30 claude --version 2>&1); then
        success "Claude Code works! Version: $version_output"
    else
        warn "Binary execution test timed out (may need API key)"
        info "Try: claude --version"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}"
    cat << 'EOF'
    ╔══════════════════════════════════════════════════════╗
    ║          ✅  Installation Complete!                  ║
    ║                                                      ║
    ║  Run 'claude' to start using Claude Code             ║
    ║                                                      ║
    ║  First time? Set your API key:                       ║
    ║  export ANTHROPIC_API_KEY="sk-ant-..."               ║
    ║                                                      ║
    ║  Or configure in ~/.claude/settings.json:            ║
    ║  {                                                   ║
    ║    "env": {                                          ║
    ║      "ANTHROPIC_API_KEY": "sk-ant-...",              ║
    ║      "ANTHROPIC_BASE_URL": "https://your-proxy/v1"  ║
    ║    }                                                 ║
    ║  }                                                   ║
    ╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ============================================================================
# Update Mode
# ============================================================================

update_claude_code() {
    banner
    info "Updating Claude Code..."

    # Uninstall current version
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true

    # Install latest
    npm install -g @anthropic-ai/claude-code --force

    # Get new version
    CLAUDE_DIR="$(npm root -g)/@anthropic-ai/claude-code"
    LATEST_VERSION="$(node -e "console.log(require('$CLAUDE_DIR/package.json').version)" 2>/dev/null || echo "")"
    BINARY_PATH="$CLAUDE_DIR/bin/claude.exe"

    success "Updated to v${LATEST_VERSION}"

    # Re-apply patches
    patch_platform_mapping
    install_musl_binary
    patch_musl_runtime
    setup_wrapper

    # Verify
    echo ""
    if timeout 30 claude --version 2>&1; then
        success "Claude Code v${LATEST_VERSION} is ready!"
    else
        warn "Claude Code updated but may need reconfiguration"
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Check for --update flag
    if [[ "${1:-}" == "--update" ]] || [[ "${1:-}" == "-u" ]]; then
        update_claude_code
        exit 0
    fi

    banner

    # Set paths after install
    CLAUDE_DIR="$(npm root -g)/@anthropic-ai/claude-code"
    BINARY_PATH="$CLAUDE_DIR/bin/claude.exe"
    WRAPPER_PATH="/data/data/com.termux/files/usr/bin/claude"

    # Run all phases
    check_android
    install_dependencies
    install_claude_code
    patch_platform_mapping
    install_musl_binary
    patch_musl_runtime
    setup_wrapper
    verify_installation
}

main "$@"
