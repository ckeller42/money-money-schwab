#!/bin/bash
# Convert the latest Schwab Equity Awards .xlsx export to CSV and sync it
# into MoneyMoney's sandbox.
#
# Usage:
#   schwab-sync                          # finds latest .xlsx in ~/Downloads
#   schwab-sync --from-staging <path>    # uses a staging file (used by SchwabSync.app)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERTER="$SCRIPT_DIR/xlsx2csv"
DATA_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/SchwabData"
mkdir -p "$DATA_DIR"
TARGET="$DATA_DIR/schwab_eac.csv"

cleanup_staging() {
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}

# Sanity check: does the CSV have the sections we expect?
# Returns non-zero on failure so callers can abort BEFORE replacing a
# known-good target with a hollow file.
validate_csv() {
  local file="$1"
  local errors=""

  if ! grep -q "EQUITY AWARD SHARES" "$file"; then
    errors="${errors}Missing EQUITY AWARD SHARES section. "
  fi
  if ! grep -q "EMPLOYEE STOCK PURCHASE PLAN" "$file"; then
    errors="${errors}Missing ESPP section. "
  fi

  # Check that we can find at least one data row (a line starting with a date).
  # Converter emits unquoted rows; older CSVs quoted them — accept both.
  if ! grep -qE '^[[:space:]]*"?[0-9]' "$file"; then
    errors="${errors}No data rows found. "
  fi

  if [ -n "$errors" ]; then
    echo "✗ CSV validation failed: $errors"
    osascript -e "display notification \"$errors\" with title \"Schwab Sync: Bad Export\"" 2>/dev/null
    return 1
  fi
}

# Trigger a MoneyMoney refresh so it re-reads the just-synced CSV. MoneyMoney
# only re-reads the file on an account refresh, and its AppleScript dictionary
# has no refresh command — so click the first item of the Ablage/File menu
# ("Alle Konten aktualisieren") via System Events, same as SchwabSync.app.
# Degrades to a "refresh manually" notification if MoneyMoney isn't running or
# Accessibility permission is missing.
refresh_moneymoney() {
  if ! pgrep -xq MoneyMoney; then
    osascript -e 'display notification "Synced. Open MoneyMoney and refresh (⌘R)." with title "Schwab Sync"' 2>/dev/null
    return
  fi
  if osascript <<'APPLESCRIPT' 2>/dev/null
tell application "MoneyMoney" to activate
delay 1
tell application "System Events" to tell process "MoneyMoney"
  repeat with menuName in {"Ablage", "File"}
    try
      click menu item 1 of menu 1 of menu bar item (menuName as text) of menu bar 1
      return
    end try
  end repeat
  error "menu not found"
end tell
APPLESCRIPT
  then
    osascript -e 'display notification "Synced. Accounts are refreshing." with title "Schwab Sync"' 2>/dev/null
  else
    osascript -e 'display notification "Synced. Refresh MoneyMoney manually (⌘R)." with title "Schwab Sync"' 2>/dev/null
  fi
}

if [ "$1" = "--from-staging" ]; then
  STAGING="$2"
  if [ -z "$STAGING" ] || [ ! -f "$STAGING" ]; then
    echo "No staging file provided"
    exit 1
  fi

  # Only set the cleanup trap once we know STAGING is a real file —
  # otherwise dirname "" yields "." and cleanup would target the cwd.
  STAGING_DIR="$(dirname "$STAGING")"
  trap cleanup_staging EXIT

  TMP_CSV="$(mktemp)"
  if ! perl "$CONVERTER" "$STAGING" > "$TMP_CSV"; then
    rm -f "$TMP_CSV"
    echo "✗ Failed to convert staging file"
    exit 1
  fi

  # Validate BEFORE replacing the target — a bad export must never
  # clobber a known-good CSV.
  if ! validate_csv "$TMP_CSV"; then
    rm -f "$TMP_CSV"
    echo "✗ Keeping existing data — staging file doesn't look like a Schwab EAC export"
    exit 1
  fi

  if [ -f "$TARGET" ] && cmp -s "$TMP_CSV" "$TARGET"; then
    rm -f "$TMP_CSV"
    echo "Already up to date"
  else
    mv "$TMP_CSV" "$TARGET"
    echo "✓ Synced from staging"
    refresh_moneymoney
  fi
else
  EAC=$(ls -t "$HOME/Downloads"/EquityAwardsCenter*.xlsx 2>/dev/null | head -1)
  if [ -z "$EAC" ]; then
    echo "No EquityAwardsCenter .xlsx found in ~/Downloads"
    exit 1
  fi

  TMP_CSV="$(mktemp)"
  if ! perl "$CONVERTER" "$EAC" > "$TMP_CSV"; then
    rm -f "$TMP_CSV"
    echo "✗ Failed to convert $(basename "$EAC")"
    exit 1
  fi

  # Validate BEFORE replacing the target — a bad export must never
  # clobber a known-good CSV.
  if ! validate_csv "$TMP_CSV"; then
    rm -f "$TMP_CSV"
    echo "✗ Keeping existing data — $(basename "$EAC") doesn't look like a Schwab EAC export"
    exit 1
  fi

  if [ -f "$TARGET" ] && cmp -s "$TMP_CSV" "$TARGET"; then
    rm -f "$TMP_CSV"
    echo "Already up to date: $(basename "$EAC")"
  else
    mv "$TMP_CSV" "$TARGET"
    echo "✓ Synced: $(basename "$EAC")"
    refresh_moneymoney
  fi
fi
