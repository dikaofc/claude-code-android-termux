#!/usr/bin/env bash
# ============================================================================
# Claude Code — Android Termux Uninstaller
# ============================================================================
# Removes Claude Code and all patched files from Termux.
# ============================================================================

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

info()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }

TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CC_LIB="${TERMUX_PREFIX}/lib"

printf "${BOLD}${CYAN}━━━ Uninstalling Claude Code from Termux ━━━${RESET}\n\n"

# 1. Uninstall the npm package
if npm list -g @anthropic-ai/claude-code &>/dev/null 2>&1; then
  info "Uninstalling Claude Code npm package..."
  npm uninstall -g @anthropic-ai/claude-code 2>/dev/null && ok "npm package removed" || warn "npm uninstall failed"
fi

# 2. Remove musl libraries
for f in "${CC_LIB}/ld-musl-aarch64.so.1" "${CC_LIB}/libc.musl-aarch64.so.1"; do
  if [ -f "$f" ]; then
    rm -f "$f" && ok "Removed $(basename "$f")"
  fi
done

# 3. Remove backup files
find "${TERMUX_PREFIX}/lib/node_modules" -name "*.bak" -path "*claude-code*" 2>/dev/null | while read -r f; do
  rm -f "$f" && ok "Removed backup: $(basename "$f")"
done

# 4. Remove the claude binary link
CLAUDE_BIN="${TERMUX_PREFIX}/bin/claude"
if [ -f "$CLAUDE_BIN" ] || [ -L "$CLAUDE_BIN" ]; then
  rm -f "$CLAUDE_BIN" && ok "Removed $CLAUDE_BIN"
fi

# 5. Remove the no-root DNS proxy + any running instance
DNS_PROXY="${TERMUX_PREFIX}/bin/dnsproxy.py"
[ -f "$DNS_PROXY" ] && rm -f "$DNS_PROXY" && ok "Removed $DNS_PROXY"
[ -f "${TERMUX_PREFIX}/tmp/dnsproxy.log" ] && rm -f "${TERMUX_PREFIX}/tmp/dnsproxy.log"
if pgrep -f 'dnsproxy.py' >/dev/null 2>&1; then
  pkill -f 'dnsproxy.py' 2>/dev/null && ok "Stopped running DNS proxy"
fi

printf "\n${GREEN}✓ Claude Code has been uninstalled.${RESET}\n\n"
