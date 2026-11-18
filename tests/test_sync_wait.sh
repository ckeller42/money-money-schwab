#!/bin/bash
# Test for `sync.sh --wait`. Each case runs against a fresh temp HOME, so the
# real MoneyMoney container is never touched. SCHWAB_SYNC_TEST=1 disables
# `open`, every osascript call and the MoneyMoney refresh.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$DIR/tests/fixtures/sample_eac.xlsx"
EXPECTED="$(cat "$DIR/tests/fixtures/expected_eac.csv")"
FAILED=0

new_home() {
  HOME="$(mktemp -d)"
  export HOME
  mkdir -p "$HOME/Downloads"
  TARGET="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/SchwabData/schwab_eac.csv"
}

# run_sync: run sync.sh --wait, capture output in OUT and status in RC.
run_sync() {
  RC=0
  OUT="$(SCHWAB_SYNC_TEST=1 bash "$DIR/sync.sh" --wait 2>&1)" || RC=$?
}

# check NAME CONDITION...: PASS if the command succeeds.
check() {
  local name=$1
  shift
  if "$@"; then
    echo "$name: PASS"
  else
    echo "$name: FAIL (rc=$RC)"
    printf '%s\n' "$OUT"
    FAILED=1
  fi
}

target_is_expected() { [ "$(cat "$TARGET")" = "$EXPECTED" ]; }
out_has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
ok_and_synced() { [ "$RC" -eq 0 ] && out_has "✓ Synced" && target_is_expected; }
ok_and_current() { [ "$RC" -eq 0 ] && out_has "Already up to date"; }
failed_keeps_target() { [ "$RC" -ne 0 ] && target_is_expected; }
synced_new() { [ "$RC" -eq 0 ] && out_has "EquityAwardsCenter_new.xlsx"; }
timed_out() { [ "$RC" -ne 0 ] && out_has "No new EquityAwardsCenter" && [ ! -e "$TARGET" ]; }

new_home
cp "$FIXTURE" "$HOME/Downloads/EquityAwardsCenter_EquityDetails_test.xlsx"
run_sync
check recent_file_synced_immediately ok_and_synced

run_sync
check second_run_up_to_date ok_and_current

printf garbage > "$HOME/Downloads/EquityAwardsCenter_EquityDetails_test.xlsx"
run_sync
check bad_export_keeps_target failed_keeps_target

new_home
cp "$FIXTURE" "$HOME/Downloads/EquityAwardsCenter_old.xlsx"
touch -t 200001010000 "$HOME/Downloads/EquityAwardsCenter_old.xlsx"
(sleep 3 && cp "$FIXTURE" "$HOME/Downloads/EquityAwardsCenter_new.xlsx") &
SCHWAB_SYNC_WAIT_SECS=20 run_sync
wait
check old_file_is_ignored_then_new_one_synced synced_new

new_home
SCHWAB_SYNC_WAIT_SECS=3 run_sync
check timeout_without_export timed_out

[ "$FAILED" -eq 0 ] || exit 1
