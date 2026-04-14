#!/usr/bin/env bash
set -euo pipefail

# UseTrack Collector — Install / Uninstall LaunchAgent
# Usage:
#   ./config/install.sh          Install and start the collector
#   ./config/install.sh --uninstall   Stop and remove the collector

LABEL="com.usetrack.collector"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.usetrack.collector.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.usetrack.collector.plist"
BINARY_SRC="$(cd "$(dirname "$0")/.." && pwd)/.build/release/UseTrackCollector"
BINARY_DST="/usr/local/bin/UseTrackCollector"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; NC="\033[0m"

if [[ "${1:-}" == "--uninstall" ]]; then
    echo -e "${YELLOW}Uninstalling UseTrack Collector...${NC}"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DST"
    rm -f "$BINARY_DST"
    echo -e "${GREEN}✓ UseTrack Collector uninstalled${NC}"
    exit 0
fi

echo "Installing UseTrack Collector..."

# 1. Build release binary
echo "  Building release binary..."
(cd "$(dirname "$0")/.." && swift build -c release 2>&1)
if [[ ! -f "$BINARY_SRC" ]]; then
    echo -e "${RED}✗ Release build failed${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ Build complete${NC}"

# 2. Copy binary
echo "  Installing binary to $BINARY_DST..."
cp "$BINARY_SRC" "$BINARY_DST"
chmod +x "$BINARY_DST"
echo -e "  ${GREEN}✓ Binary installed${NC}"

# 3. Install plist
echo "  Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__HOME__|$HOME|g" -e "s|__BINARY_DST__|$BINARY_DST|g" "$PLIST_SRC" > "$PLIST_DST"
echo -e "  ${GREEN}✓ LaunchAgent plist installed${NC}"

# 4. Load and start
echo "  Starting collector..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo -e "  ${GREEN}✓ Collector started${NC}"

echo ""
echo -e "${GREEN}UseTrack Collector is now running!${NC}"
echo "  Logs: /tmp/usetrack-collector.stdout.log"
echo "  DB:   ~/.usetrack/usetrack.db"
echo "  Stop: launchctl bootout gui/$(id -u)/$LABEL"
echo "  Remove: $0 --uninstall"
