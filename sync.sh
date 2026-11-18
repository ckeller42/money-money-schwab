#!/bin/bash
# Convert a Schwab Equity Awards .xlsx export to CSV and sync it into
# MoneyMoney's sandbox.
#
# Usage:
#   sync.sh          # converts the newest ~/Downloads/EquityAwardsCenter*.xlsx
#   sync.sh --wait   # opens Schwab, waits for a fresh export in ~/Downloads, syncs it
#
# Environment:
#   SCHWAB_SYNC_WAIT_SECS  --wait timeout in seconds (default 900)
#   SCHWAB_SYNC_TEST=1     disable `open`, every osascript call and the
#                          MoneyMoney refresh (used by tests)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERTER="$SCRIPT_DIR/xlsx2csv"
DATA_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/SchwabData"
mkdir -p "$DATA_DIR"
TARGET="$DATA_DIR/schwab_eac.csv"
SCHWAB_URL="https://client.schwab.com/app/accounts/equityawards/#/equityTodayView"

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
    [ -n "$SCHWAB_SYNC_TEST" ] || osascript -e "display notification \"$errors\" with title \"Schwab Sync: Bad Export\"" 2>/dev/null || true
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
  [ -n "$SCHWAB_SYNC_TEST" ] && return 0
  if ! pgrep -xq MoneyMoney; then
    osascript -e 'display notification "Synced. Open MoneyMoney and refresh (⌘R)." with title "Schwab Sync"' 2>/dev/null || true
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
    osascript -e 'display notification "Synced. Accounts are refreshing." with title "Schwab Sync"' 2>/dev/null || true
  else
    osascript -e 'display notification "Synced. Refresh MoneyMoney manually (⌘R)." with title "Schwab Sync"' 2>/dev/null || true
  fi
}

# sync_xlsx XLSX: convert, validate, compare, move, refresh.
# Order matters: a bad export must never replace a known-good target.
sync_xlsx() {
  local xlsx="$1" name tmp
  name="$(basename "$xlsx")"
  tmp="$(mktemp)"
  if ! perl "$CONVERTER" "$xlsx" > "$tmp"; then
    rm -f "$tmp"
    echo "✗ Failed to convert $name"
    return 1
  fi
  if ! validate_csv "$tmp"; then
    rm -f "$tmp"
    echo "✗ Keeping existing data — $name doesn't look like a Schwab EAC export"
    return 1
  fi
  if [ -f "$TARGET" ] && cmp -s "$tmp" "$TARGET"; then
    rm -f "$tmp"
    echo "Already up to date: $name"
    return 0
  fi
  if ! mv "$tmp" "$TARGET"; then
    rm -f "$tmp"
    echo "✗ Failed to replace target CSV"
    return 1
  fi
  echo "✓ Synced: $name"
  refresh_moneymoney
}

# newest_recent_export MINUTES: newest EquityAwardsCenter*.xlsx in
# ~/Downloads modified within MINUTES minutes; prints nothing if none.
newest_recent_export() {
  find "$HOME/Downloads" -maxdepth 1 -name 'EquityAwardsCenter*.xlsx' -mmin "-$1" \
    -exec ls -t {} + 2>/dev/null | head -1
}

if [ "$1" = "--wait" ]; then
  timeout="${SCHWAB_SYNC_WAIT_SECS:-900}"
  [ -n "$SCHWAB_SYNC_TEST" ] || open "$SCHWAB_URL"
  echo "Download the Equity Details Excel (.xlsx) from Schwab — waiting for it in ~/Downloads…"
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    EAC="$(newest_recent_export $((10 + elapsed / 60 + 1)))"
    if [ -n "$EAC" ]; then
      sync_xlsx "$EAC"
      exit $?
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "✗ No new EquityAwardsCenter*.xlsx arrived in ~/Downloads within $((timeout / 60)) minutes"
  exit 1
fi

EAC=$(ls -t "$HOME/Downloads"/EquityAwardsCenter*.xlsx 2>/dev/null | head -1)
if [ -z "$EAC" ]; then
  echo "No EquityAwardsCenter .xlsx found in ~/Downloads"
  exit 1
fi
sync_xlsx "$EAC"
