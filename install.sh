#!/bin/bash
set -e

# ── paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTENSION_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions"
DATA_DIR="$EXTENSION_DIR/SchwabData"
# Prefer /Applications (shows in Launchpad), fall back to ~/Applications
APP_DIR="/Applications"
if [ ! -w "$APP_DIR" ]; then
  APP_DIR="$HOME/Applications"
  mkdir -p "$APP_DIR"
fi

# ── preflight ──────────────────────────────────────────────────────────────
if [ ! -d "$EXTENSION_DIR" ]; then
  echo "✗ MoneyMoney not found. Install it first from https://moneymoney-app.com"
  exit 1
fi
echo "MoneyMoney found."

# ── install extension (patch home path) ────────────────────────────────────
sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/extension/SchwabPortfolio.lua" \
  > "$EXTENSION_DIR/SchwabPortfolio.lua"
echo "✓ Extension installed"

# ── create data directory ──────────────────────────────────────────────────
mkdir -p "$DATA_DIR"
echo "✓ Data directory created"

# ── shell alias ───────────────────────────────────────────────────────────
echo ""
echo "To add a shell alias, add this line to your ~/.zshrc (or ~/.bashrc):"
echo "  alias schwab-sync='$SCRIPT_DIR/sync.sh'"
echo ""

# ── build and install SchwabSync app ──────────────────────────────────────
APPLESCRIPT="$SCRIPT_DIR/shortcut/SchwabSync.applescript"
if [ -f "$APPLESCRIPT" ]; then
  mkdir -p "$APP_DIR"
  PATCHED=$(mktemp)
  sed -e "s|__SYNC_SCRIPT__|$SCRIPT_DIR/sync.sh|g" \
      -e "s|__DATA_DIR__|$DATA_DIR|g" "$APPLESCRIPT" > "$PATCHED"
  if osacompile -o "$APP_DIR/SchwabSync.app" "$PATCHED" 2>/dev/null; then
    rm "$PATCHED"
    ICNS="$SCRIPT_DIR/shortcut/SchwabSync.icns"
    if [ -f "$ICNS" ]; then
      cp "$ICNS" "$APP_DIR/SchwabSync.app/Contents/Resources/applet.icns"
      rm -f "$APP_DIR/SchwabSync.app/Contents/Resources/Assets.car"
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" \
        "$APP_DIR/SchwabSync.app/Contents/Info.plist" 2>/dev/null || true
      touch "$APP_DIR/SchwabSync.app"
    fi
    echo "✓ SchwabSync.app installed to $APP_DIR"
  else
    rm "$PATCHED"
    echo "– SchwabSync.app: could not compile (osacompile not available?)"
    echo "  You can run sync.sh manually instead."
  fi
fi

# ── initial sync ───────────────────────────────────────────────────────────
"$SCRIPT_DIR/sync.sh" || true

# ── done ───────────────────────────────────────────────────────────────────
echo ""
echo "Setup complete. Next steps:"
echo "  1. Restart MoneyMoney"
echo "  2. Hold Option (⌥) + click Help menu → enable unsigned extensions"
echo "  3. Add Account → search for 'schwab-csv' → click through (leave fields empty)"
echo "  4. Open SchwabSync from Launchpad (or Spotlight) to download + sync"
