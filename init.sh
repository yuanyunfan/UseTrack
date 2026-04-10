#!/usr/bin/env bash
set -euo pipefail

BOLD="\033[1m"; GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; NC="\033[0m"
log()   { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

echo -e "${BOLD}UseTrack — Environment Init${NC}"
echo "=================================="

# 1. Swift toolchain
if command -v swift &>/dev/null; then
    SWIFT_VER=$(swift --version 2>&1 | head -1)
    log "Swift: ${SWIFT_VER}"
else
    error "Swift not found. Install Xcode or Xcode Command Line Tools."
fi

# 2. Xcode check
if xcode-select -p &>/dev/null; then
    log "Xcode tools: $(xcode-select -p)"
else
    warn "Xcode Command Line Tools not installed. Run: xcode-select --install"
fi

# 3. Python 3.12+
if command -v python3 &>/dev/null; then
    PY_VER=$(python3 --version)
    log "Python: ${PY_VER}"
else
    error "Python 3 not found. Install via: brew install python@3.12"
fi

# 4. uv
if command -v uv &>/dev/null; then
    UV_VER=$(uv --version)
    log "uv: ${UV_VER}"
else
    warn "uv not found. Installing..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    log "uv installed"
fi

# 5. Swift build check
echo ""
echo -e "${BOLD}Building Swift project...${NC}"
if swift build 2>&1; then
    log "Swift build: OK"
else
    warn "Swift build failed (expected if Package.swift not yet created)"
fi

# 6. Python dependencies
echo ""
echo -e "${BOLD}Setting up Python environment...${NC}"
if [ -f python/pyproject.toml ]; then
    (cd python && uv sync)
    log "Python dependencies: installed"
else
    warn "python/pyproject.toml not found (will be created in Phase 0)"
fi

# 7. Database directory
mkdir -p db
log "Database directory: db/"

# 8. Git hooks
if [ -d .git ]; then
    if [ -f .githooks/pre-commit ]; then
        git config core.hooksPath .githooks
        log "Git hooks: configured"
    else
        warn "Git hooks not yet created (will be set up in Phase 0)"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}Ready!${NC}"
echo "Useful commands:"
echo "  swift build                → Build collector"
echo "  swift test                 → Run Swift tests"
echo "  uv run usetrack-mcp       → Start MCP server"
echo "  uv run pytest             → Run Python tests"
echo "  uv run usetrack-report    → Generate daily report"
