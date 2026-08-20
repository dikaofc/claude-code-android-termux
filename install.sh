#!/usr/bin/env bash
# ============================================================================
# Claude Code for Android Termux — Installer
# ============================================================================
# Repository : https://github.com/dikaofc/claude-code-android-termux
# License    : MIT
#
# What this does:
#   1. Checks the environment (Android / Termux / ARM64 / Node.js)
#   2. Installs the dependencies needed to run the musl binary
#   3. Installs Claude Code itself via npm
#   4. Patches the platform mapping (android -> musl) in the npm scripts
#   5. Downloads the real ARM64 musl binary package
#   6. Patches the ELF to use the Termux-installed musl loader
#   7. Installs a no-root DNS fix (dnsproxy.py) + the `claude` wrapper
#
# DNS fix (why dnsproxy.py?):
#   The Claude Code binary is Bun/musl. On Android, /etc/resolv.conf does
#   not exist (read-only /system), so the binary's DNS resolution fails and
#   Claude shows "API error · Retrying" forever. /etc cannot be written
#   without root, and proot breaks child-process execution of the musl
#   binary. Instead of fighting the filesystem, we run a tiny localhost
#   HTTP CONNECT proxy (dnsproxy.py, pure python3, NO root, NO proot).
#   The claude wrapper points HTTPS_PROXY at it; the proxy resolves DNS
#   using Android's *native* resolver (which works fine) and tunnels the
#   binary's HTTPS traffic. Everything just works.
#
# run as:
#   sh install.sh           # dash -> auto re-execs under bash
#   bash install.sh         # direct
#   bash install.sh --update
# ============================================================================

# ---- dash compatibility: `sh install.sh` must work ------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "[INFO] This script requires bash — re-invoking with bash..."
    exec bash "$0" "$@"
fi

set -euo pipefail

# ---- colors ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo ""; echo -e "${CYAN}${BOLD}━━━ Step $1: $2 ━━━${NC}"; }

banner() {
    cat << 'EOF'

    ╔══════════════════════════════════════════════════════╗
    ║         Claude Code · Android Termux Installer       ║
    ║            ARM64 + musl · no-root DNS fix            ║
    ╚══════════════════════════════════════════════════════╝
EOF
}

# ---- global state ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
USR_BIN="$PREFIX/bin"
MUSL_LIB="$PREFIX/lib"
CLAUDE_DIR="$(npm root -g 2>/dev/null)/@anthropic-ai/claude-code"
BINARY_PATH="$CLAUDE_DIR/bin/claude.exe"
WRAPPER_PATH="$USR_BIN/claude"
DNS_PROXY_SRC="$SCRIPT_DIR/assets/dnsproxy.py"
DNS_PROXY_DST="$USR_BIN/dnsproxy.py"
SKILLS_SRC="$SCRIPT_DIR/skills"
SKILLS_DST="${CLAUDE_HOME:-$HOME/.claude}/skills"
CURRENT_VERSION=""

# ============================================================================
# Phase 1 — Environment
# ============================================================================
check_environment() {
    step "1/8" "Checking environment"

    if [ "$(uname -o 2>/dev/null)" != "Android" ]; then
        error "Not running on Android. This installer is for Termux only."
    fi
    success "Android/Termux detected"

    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64) success "Architecture: $arch" ;;
        *) error "ARM64 (aarch64) required. Detected: $arch" ;;
    esac

    if ! command -v node &>/dev/null; then
        warn "Node.js not found. Installing..."
        pkg install -y nodejs
    fi
    local node_major
    node_major="$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)"
    if [ -z "$node_major" ] || [ "$node_major" -lt 22 ] 2>/dev/null; then
        warn "Node.js >= 22 required — installing latest..."
        pkg install -y nodejs
    fi
    success "Node.js: $(node -v) · npm: $(npm -v)"

    if [ -d "$CLAUDE_DIR" ]; then
        CURRENT_VERSION="$(node -e "console.log(require('$CLAUDE_DIR/package.json').version)" 2>/dev/null || echo "")"
        [ -n "$CURRENT_VERSION" ] && info "Claude Code v$CURRENT_VERSION already present"
    fi
}

# ============================================================================
# Phase 2 — Dependencies
# ============================================================================
install_dependencies() {
    step "2/8" "Installing dependencies"

    local deps_needed=()
    # curl        — downloading the musl runtime
    # patchelf    — repointing the ELF interpreter/RPATH
    # python3     — runtime for dnsproxy.py (the no-root DNS fix)
    command -v curl     &>/dev/null || deps_needed+=("curl")
    command -v patchelf &>/dev/null || deps_needed+=("patchelf")
    command -v python3  &>/dev/null || deps_needed+=("python3")

    if [ "${#deps_needed[@]}" -gt 0 ]; then
        pkg install -y "${deps_needed[@]}"
        success "Dependencies installed: ${deps_needed[*]}"
    else
        success "All dependencies already installed"
    fi
}

# ============================================================================
# Phase 3 — Install / Update Claude Code
# ============================================================================
install_claude_code() {
    step "3/8" "Installing Claude Code"

    if [ -n "$CURRENT_VERSION" ]; then
        # LD_PRELOAD (Termux exec helper) breaks the musl binary — unset it
        # before testing, otherwise even a healthy binary looks broken and
        # the reinstall would clobber it with npm's stub.
        if timeout 10 env -u LD_PRELOAD "$BINARY_PATH" --version &>/dev/null 2>&1; then
            success "Claude Code v${CURRENT_VERSION} already installed and working"
            return 0
        fi
        warn "Claude Code present but binary not working — reinstalling..."
    fi

    info "Installing via npm (this may take a minute)..."
    if npm install -g @anthropic-ai/claude-code --force 2>&1 | tail -5; then
        CLAUDE_DIR="$(npm root -g)/@anthropic-ai/claude-code"
        CURRENT_VERSION="$(node -e "console.log(require('$CLAUDE_DIR/package.json').version)" 2>/dev/null || echo "")"
        success "Claude Code v${CURRENT_VERSION} installed"
    else
        error "npm install failed"
    fi
    # Platform mapping is patched in Step 4 (npm may overwrite patched files).
}

# ============================================================================
# Phase 4 — Platform mapping (android -> musl)
# ============================================================================
patch_platform_mapping() {
    step "4/8" "Patching platform mapping (android → musl)"

    local patched=0
    local f

    for f in "$CLAUDE_DIR/install.cjs" "$CLAUDE_DIR/cli-wrapper.cjs"; do
        [ -f "$f" ] || continue
        if grep -q "linux-' + cpu + '-android" "$f" 2>/dev/null; then
            info "Patching $(basename "$f")..."
            sed -i "s/return 'linux-' + cpu + '-android'/return 'linux-' + cpu + '-musl'/g" "$f"
            success "$(basename "$f") patched"
            patched=$((patched + 1))
        else
            success "$(basename "$f") already patched"
        fi
    done

    if [ "$patched" -eq 0 ]; then
        success "Platform mapping already correct"
    fi
    return 0
}

# ============================================================================
# Phase 5 — musl binary (the real ARM64 binary from npm)
# ============================================================================
install_musl_binary() {
    step "5/8" "Installing musl binary"

    local bin_size
    bin_size=$(stat -c%s "$BINARY_PATH" 2>/dev/null || echo 0)

    if [ "$bin_size" -gt 100000000 ] 2>/dev/null \
        && readelf -d "$BINARY_PATH" 2>/dev/null | grep -q "musl"; then
        success "musl binary already in place ($(numfmt --to=iec "$bin_size" 2>/dev/null || echo "$bin_size bytes"))"
        return 0
    fi

    info "Downloading musl binary via npm (may take a minute)..."
    npm install -g "@anthropic-ai/claude-code-linux-arm64-musl@$CURRENT_VERSION" --force 2>&1 | tail -5 \
        || error "Failed to download musl binary package"

    info "Running postinstall (copies binary into place)..."
    ( cd "$CLAUDE_DIR" && node install.cjs 2>&1 | tail -3 )

    bin_size=$(stat -c%s "$BINARY_PATH" 2>/dev/null || echo 0)
    [ "$bin_size" -lt 100000000 ] 2>/dev/null && error "Binary install failed (size: $bin_size bytes)"
    success "musl binary installed ($(numfmt --to=iec "$bin_size" 2>/dev/null || echo "$bin_size bytes"))"
}

# ============================================================================
# Phase 6 — musl runtime + ELF patching
# ============================================================================
patch_musl_runtime() {
    step "6/8" "Patching musl runtime"

    local interpreter
    interpreter="$(readelf -l "$BINARY_PATH" 2>/dev/null | grep "interpreter" | sed 's/.*: //' | sed 's/].*//' || true)"
    if echo "$interpreter" | grep -q "com.termux"; then
        success "Binary already patched → interpreter: $interpreter"
        return 0
    fi

    if [ ! -f "$MUSL_LIB/ld-musl-aarch64.so.1" ]; then
        info "Downloading musl runtime from Alpine Linux..."

        # Resolve the current musl package version dynamically instead of
        # pinning one: Alpine renames apk files per release (e.g. 1.2.5-r11),
        # and a hardcoded stale name returns 404 on fresh installs.
        local tmpdir
        tmpdir="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
        mkdir -p "$tmpdir"

        local mirror listed pkg
        for mirror in "https://dl-cdn.alpinelinux.org" "https://uk.alpinelinux.org"; do
            listed=$(curl -fsSL --max-time 20 "$mirror/alpine/v3.21/main/aarch64/" 2>/dev/null \
                | grep -o 'musl-[0-9][^"]*\.apk' | sort -V | tail -1 || true)
            [ -n "$listed" ] && break
        done
        if [ -n "$listed" ]; then
            pkg="$listed"
            info "Found musl package: $pkg"
        else
            # Last-resort fallback list of known-good versions
            for pkg in musl-1.2.5-r11.apk musl-1.2.5-r8.apk; do
                curl -fsSL --max-time 20 -o "$tmpdir/musl.apk" \
                    "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/$pkg" 2>/dev/null && break || pkg=""
            done
        fi

        curl -fsSL --max-time 60 -o "$tmpdir/musl.apk" \
            "${mirror:-https://dl-cdn.alpinelinux.org}/alpine/v3.21/main/aarch64/$pkg" \
            || error "Failed to download musl runtime ($pkg)"

        mkdir -p "$tmpdir/musl-extract"
        tar xzf "$tmpdir/musl.apk" -C "$tmpdir/musl-extract" 2>/dev/null \
            || tar xf "$tmpdir/musl.apk" -C "$tmpdir/musl-extract" 2>/dev/null

        cp "$tmpdir/musl-extract/lib/ld-musl-aarch64.so.1" "$MUSL_LIB/"
        cp "$tmpdir/musl-extract/lib/libc.musl-aarch64.so.1" "$MUSL_LIB/"
        chmod 755 "$MUSL_LIB/ld-musl-aarch64.so.1" "$MUSL_LIB/libc.musl-aarch64.so.1"
        rm -rf "$tmpdir/musl.apk" "$tmpdir/musl-extract"
        success "musl runtime downloaded"
    else
        success "musl runtime already present"
    fi

    info "Patching ELF interpreter/RPATH with patchelf..."
    patchelf --set-interpreter "$MUSL_LIB/ld-musl-aarch64.so.1" "$BINARY_PATH"
    patchelf --set-rpath "$MUSL_LIB" "$BINARY_PATH"

    interpreter="$(readelf -l "$BINARY_PATH" 2>/dev/null | grep "interpreter" | sed 's/.*: //' | sed 's/].*//' || true)"
    if echo "$interpreter" | grep -q "com.termux"; then
        success "Patch verified → interpreter: $interpreter"
    else
        error "Patch verification failed"
    fi
}

# ============================================================================
# Phase 7 — dnsproxy (no-root DNS) + `claude` wrapper
# ============================================================================
setup_wrapper() {
    step "7/8" "Installing DNS fix + wrapper"

    # --- install the no-root DNS proxy ------------------------------------
    if [ -f "$DNS_PROXY_SRC" ]; then
        cp "$DNS_PROXY_SRC" "$DNS_PROXY_DST"
        chmod +x "$DNS_PROXY_DST"
        success "DNS proxy installed → $DNS_PROXY_DST"
    else
        # Fallback: embed the proxy directly (works even if assets/ is missing)
        cat > "$DNS_PROXY_DST" << 'PYEOF'
#!/usr/bin/env python3
import socket, sys, threading
HOST, PORT, BUF = "127.0.0.1", 8080, 65536
def pipe(a, b):
    try:
        while True:
            d = a.recv(BUF)
            if not d: break
            b.sendall(d)
    except OSError: pass
    finally:
        try: b.shutdown(socket.SHUT_WR)
        except OSError: pass
def handle(c, a):
    try:
        c.settimeout(30); req = b""
        while b"\r\n\r\n" not in req:
            ch = c.recv(BUF)
            if not ch: return
            req += ch
            if len(req) > 16384: return
        ln = req.split(b"\r\n", 1)[0].decode("latin-1", "replace").split()
        if len(ln) < 2 or ln[0].upper() != "CONNECT":
            c.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n"); return
        h, _, p = ln[1].rpartition(":"); p = int(p or 443)
        ip = socket.gethostbyname(h)
        u = socket.create_connection((ip, p), timeout=15)
        c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        c.settimeout(None); u.settimeout(None)
        t1 = threading.Thread(target=pipe, args=(c, u), daemon=True)
        t2 = threading.Thread(target=pipe, args=(u, c), daemon=True)
        t1.start(); t2.start(); t1.join(); t2.join()
    except Exception: pass
    finally:
        try: c.close()
        except OSError: pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((HOST, PORT)); srv.listen(64)
print(f"dnsproxy: listening on {HOST}:{PORT}", flush=True)
while True:
    c, a = srv.accept()
    threading.Thread(target=handle, args=(c, a), daemon=True).start()
PYEOF
        chmod +x "$DNS_PROXY_DST"
        warn "assets/dnsproxy.py not found — embedded fallback installed"
    fi

    # --- remove npm's symlink, then install our wrapper --------------------
    [ -L "$WRAPPER_PATH" ] && rm -f "$WRAPPER_PATH"

    cat > "$WRAPPER_PATH" << 'WRAPPER'
#!/bin/sh
# ============================================================================
# claude — Claude Code wrapper for Android Termux
#
# Two fixes:
#  1. LD_PRELOAD — Termux's bionic exec helper breaks the musl binary
#     (relocation errors), so we strip it before exec.
#  2. DNS — the musl (Bun) binary can't read Android's /etc/resolv.conf
#     (it doesn't exist; /system is read-only) so DNS hangs and Claude
#     shows "API error · Retrying" forever.  Fix: point HTTPS_PROXY at a
#     tiny localhost CONNECT proxy (dnsproxy.py) that resolves via
#     Android's own resolver. No root, no proot.
# ============================================================================

unset LD_PRELOAD

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PROXY_BIN="$PREFIX/bin/dnsproxy.py"
CLAUDE_EXE="@@BINARY_PATH@@"

# --- 1. load ANTHROPIC_* from ~/.claude/settings.json if not set ----------
if [ -f "$HOME/.claude/settings.json" ]; then
    for _v in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL; do
        if [ -z "$(eval echo \$$_v)" ]; then
            _val=$(grep -o "\"$_v\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
            [ -n "$_val" ] && export "$_v=$_val"
        fi
    done
fi
export NODE_TLS_REJECT_UNAUTHORIZED="0"

# --- 2. ensure the DNS proxy is running -----------------------------------
if [ -x "$PREFIX/bin/python3" ] && [ -f "$PROXY_BIN" ]; then
    _port="${CLAUDE_DNS_PROXY_PORT:-8080}"
    if ! "$PREFIX/bin/python3" - "$_port" >/dev/null 2>&1 <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)   # already answering
except Exception:
    sys.exit(1)   # not running -> start it
finally:
    s.close()
PYEOF
    then
        setsid "$PREFIX/bin/python3" "$PROXY_BIN" "$_port" >"$PREFIX/tmp/dnsproxy.log" 2>&1 </dev/null &
        sleep 1
    fi
    # Make the binary use the proxy (DNS is resolved by Android itself)
    export HTTPS_PROXY="http://127.0.0.1:$_port"
    export HTTP_PROXY="http://127.0.0.1:$_port"
fi

exec "$CLAUDE_EXE" "$@"
WRAPPER

    sed -i "s|@@BINARY_PATH@@|$BINARY_PATH|g" "$WRAPPER_PATH"
    chmod +x "$WRAPPER_PATH"

    success "Wrapper created → $WRAPPER_PATH"
}

# ============================================================================
# Custom skills (Agent Skills standard -> ~/.claude/skills)
# ============================================================================
install_skills() {
    step "8/8" "Installing custom skills"

    if [ ! -d "$SKILLS_SRC" ]; then
        warn "No skills/ directory found in repo — skipping"
        return 0
    fi

    mkdir -p "$SKILLS_DST"
    local count=0
    local skill
    for skill in "$SKILLS_SRC"/*/; do
        [ -d "$skill" ] || continue
        name="$(basename "$skill")"
        if [ -f "$skill/SKILL.md" ]; then
            cp -r "$skill" "$SKILLS_DST/"
            success "Skill installed → $SKILLS_DST/$name"
            count=$((count + 1))
        else
            warn "Skipping $name (no SKILL.md)"
        fi
    done

    if [ "$count" -eq 0 ]; then
        warn "No valid skills found"
    else
        info "$count skill(s) installed. Claude Code auto-loads them from ~/.claude/skills"
    fi
    return 0
}

# ============================================================================
# Verification
# ============================================================================
verify_installation() {
    echo ""
    echo -e "${GREEN}${BOLD}━━━ Verifying Installation ━━━${NC}"

    [ -x "$WRAPPER_PATH" ] || error "Wrapper missing at $WRAPPER_PATH"
    [ "$(stat -c%s "$BINARY_PATH" 2>/dev/null || echo 0)" -lt 100000000 ] \
        && error "Binary not properly installed"

    info "Testing binary — this needs network access to your API endpoint..."
    timeout 40 "$WRAPPER_PATH" --version 2>&1 | head -1
    info "Full API test happens on first run (run: claude)"
}

# ============================================================================
# Update mode
# ============================================================================
update_claude_code() {
    banner
    info "Updating Claude Code..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    npm install -g @anthropic-ai/claude-code --force 2>&1 | tail -3

    CLAUDE_DIR="$(npm root -g)/@anthropic-ai/claude-code"
    CURRENT_VERSION="$(node -e "console.log(require('$CLAUDE_DIR/package.json').version)" 2>/dev/null || echo "")"
    BINARY_PATH="$CLAUDE_DIR/bin/claude.exe"
    success "Updated to v${CURRENT_VERSION}"

    patch_platform_mapping
    install_musl_binary
    patch_musl_runtime
    setup_wrapper
    install_skills
    verify_installation
}

# ============================================================================
# Main
# ============================================================================
main() {
    if [ "${1:-}" = "--update" ] || [ "${1:-}" = "-u" ]; then
        update_claude_code
        exit 0
    fi

    banner
    check_environment
    install_dependencies
    install_claude_code
    patch_platform_mapping
    install_musl_binary
    patch_musl_runtime
    setup_wrapper
    install_skills
    verify_installation

    echo ""
    echo -e "${GREEN}${BOLD}          ✅  Installation Complete!${NC}"
    echo ""
    echo "  Run:  claude"
    echo "  API:  on first run Claude uses ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL"
    echo "        from ~/.claude/settings.json (or environment variables)."
    echo ""
}

main "$@"