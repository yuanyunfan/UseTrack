#!/usr/bin/env bash
set -euo pipefail

# UseTrack MenuBar — Install / Uninstall LaunchAgent
# Usage:
#   ./config/install-menubar.sh            Install and start the menubar app
#   ./config/install-menubar.sh --uninstall   Stop and remove the menubar app
#
# Same user-local approach as install.sh: no sudo, lives under $HOME.

LABEL="com.usetrack.menubar"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.usetrack.menubar.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.usetrack.menubar.plist"
BINARY_SRC="$(cd "$(dirname "$0")/.." && pwd)/.build/release/UseTrackMenuBar"
BINARY_DST="$HOME/bin/UseTrackMenuBar"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; NC="\033[0m"

if [[ "${1:-}" == "--uninstall" ]]; then
    echo -e "${YELLOW}Uninstalling UseTrack MenuBar...${NC}"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DST"
    rm -f "$BINARY_DST"
    echo -e "${GREEN}✓ UseTrack MenuBar uninstalled${NC}"
    exit 0
fi

if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}✗ Do NOT run with sudo. MenuBar must run as the GUI user.${NC}"
    exit 1
fi

echo "Installing UseTrack MenuBar to $BINARY_DST..."

echo "  Building release binary..."
(cd "$(dirname "$0")/.." && swift build -c release --product UseTrackMenuBar 2>&1)
if [[ ! -f "$BINARY_SRC" ]]; then
    echo -e "${RED}✗ Release build failed${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ Build complete${NC}"

echo "  Installing binary..."
mkdir -p "$(dirname "$BINARY_DST")"
cp "$BINARY_SRC" "$BINARY_DST"
chmod +x "$BINARY_DST"
echo -e "  ${GREEN}✓ Binary installed${NC}"

echo "  Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__HOME__|$HOME|g" -e "s|__BINARY_DST__|$BINARY_DST|g" "$PLIST_SRC" > "$PLIST_DST"
echo -e "  ${GREEN}✓ LaunchAgent plist installed${NC}"

echo "  Starting menubar..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo -e "  ${GREEN}✓ MenuBar started${NC}"

echo ""
echo -e "${GREEN}UseTrack MenuBar is now running!${NC}"
echo "  Binary: $BINARY_DST"
echo "  Logs:   /tmp/usetrack-menubar.stdout.log"
echo "  Stop:   launchctl bootout gui/$(id -u)/$LABEL"
echo "  Remove: $0 --uninstall"
