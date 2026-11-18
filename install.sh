#!/bin/bash
set -e

# ── paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTENSION_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions"
DATA_DIR="$EXTENSION_DIR/SchwabData"
# Prefer /Applications (findable via Spotlight), fall back to ~/Applications
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

# ── Terminal launcher ──────────────────────────────────────────────────────
# A .command file opens in Terminal, which already holds the TCC grant that
# writing into MoneyMoney's container needs. The path is wrapped
# in double quotes so a checkout path with spaces still works.
LAUNCHER="$APP_DIR/Schwab Sync.command"
printf '#!/bin/bash\nexec "%s/sync.sh" --wait\n' "$SCRIPT_DIR" > "$LAUNCHER"
chmod 755 "$LAUNCHER"
echo "✓ Launcher installed: $LAUNCHER"
if [ -d "$APP_DIR/SchwabSync.app" ]; then
  echo "Old SchwabSync.app found. It can't sync on current macOS — delete it (rm -rf \"$APP_DIR/SchwabSync.app\"). Optional: delete the \"SchwabSync Signing\" key in Keychain Access."
fi

# ── initial sync ───────────────────────────────────────────────────────────
"$SCRIPT_DIR/sync.sh" || true

# ── done ───────────────────────────────────────────────────────────────────
echo ""
echo "Setup complete. Next steps:"
echo "  1. Restart MoneyMoney"
echo "  2. Hold Option (⌥) + click Help menu → enable unsigned extensions"
echo "  3. Add Account → search for 'schwab-csv' → click through (leave fields empty)"
echo "  4. Double-click \"Schwab Sync\" in $APP_DIR (or find it with Spotlight) — Terminal opens Schwab and syncs your new download."
