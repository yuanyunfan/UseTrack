#!/usr/bin/env bash
set -euo pipefail

# UseTrack Collector — Install / Uninstall LaunchAgent
# Usage:
#   ./config/install.sh          Install and start the collector
#   ./config/install.sh --uninstall   Stop and remove the collector
#
# Installs to ~/bin (user-writable, no sudo needed). The plist is rewritten
# to reference the per-user binary path so different users can run their own
# install without sudo / path collisions.

LABEL="com.usetrack.collector"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.usetrack.collector.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.usetrack.collector.plist"
BINARY_SRC="$(cd "$(dirname "$0")/.." && pwd)/.build/release/UseTrackCollector"
BINARY_DST="$HOME/bin/UseTrackCollector"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; NC="\033[0m"

if [[ "${1:-}" == "--uninstall" ]]; then
    echo -e "${YELLOW}Uninstalling UseTrack Collector...${NC}"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DST"
    rm -f "$BINARY_DST"
    echo -e "${GREEN}✓ UseTrack Collector uninstalled${NC}"
    exit 0
fi

# Refuse to run as root: we want everything owned by the invoking user so
# subsequent re-installs don't need sudo. (Old versions installed to
# /usr/local/bin which required root and trapped users in a sudo loop.)
if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}✗ Do NOT run with sudo. The new installer is user-local${NC}"
    echo "  Re-run as your normal user — the binary lives at \$HOME/bin and"
    echo "  the LaunchAgent runs as you, no root needed."
    exit 1
fi

echo "Installing UseTrack Collector to $BINARY_DST..."

# 1. Build release binary
echo "  Building release binary..."
(cd "$(dirname "$0")/.." && swift build -c release --product UseTrackCollector 2>&1)
if [[ ! -f "$BINARY_SRC" ]]; then
    echo -e "${RED}✗ Release build failed${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ Build complete${NC}"

# 2. Copy binary
echo "  Installing binary..."
mkdir -p "$(dirname "$BINARY_DST")"
cp "$BINARY_SRC" "$BINARY_DST"
chmod +x "$BINARY_DST"
echo -e "  ${GREEN}✓ Binary installed${NC}"

# 3. Install plist (substitute __HOME__ / __BINARY_DST__ placeholders)
echo "  Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__HOME__|$HOME|g" -e "s|__BINARY_DST__|$BINARY_DST|g" "$PLIST_SRC" > "$PLIST_DST"
echo -e "  ${GREEN}✓ LaunchAgent plist installed${NC}"

# 4. Load and start (bootout first so launchd re-reads the plist file —
#    plain pkill / restart would keep using the cached old plist path)
echo "  Starting collector..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo -e "  ${GREEN}✓ Collector started${NC}"

echo ""
echo -e "${GREEN}UseTrack Collector is now running!${NC}"
echo "  Binary: $BINARY_DST"
echo "  Logs:   /tmp/usetrack-collector.stdout.log"
echo "  DB:     ~/.usetrack/usetrack.db"
echo "  Stop:   launchctl bootout gui/$(id -u)/$LABEL"
echo "  Remove: $0 --uninstall"
