# Replace SchwabSync.app with a Terminal `.command` launcher

Status: approved by the owner on 2026-11-15.

## Intent

One double-click syncs the newest Schwab EAC export into MoneyMoney. Today
SchwabSync.app cannot do this on current macOS, and nothing in System
Settings can fix it.

## Why the app cannot work

- The extension can only read MoneyMoney's own container, and MoneyMoney has
  no import route for securities (no File > Import, AppleScript command, URL
  scheme, document type or watched folder). So some process outside
  MoneyMoney must write `schwab_eac.csv` into the container.
- macOS checks `kTCCServiceSystemPolicyAppDataDetailed` for that write. For
  SchwabSync.app (self-signed, stable identity) it denies the check in about
  20 ms, without a dialog, even with Full Disk Access on and after
  `tccutil reset`. There is no way for the user to grant it.
- Terminal already holds the grant: `schwab-sync` in Terminal always worked.

## Goals

- One double-click: open the Schwab page, wait for the new export, convert,
  write, refresh MoneyMoney, show the result.
- No file picker: the "picked an old export" mistake becomes impossible.
- Less machinery: no app bundle, no signing key, no keychain prompt, no
  integrity check.

## Non-goals

- No change to the Lua extension or to `xlsx2csv`.
- No automatic download from Schwab.

## Anti-goals

- No new permission the user has to grant beyond what Terminal already has.
- Never replace a known-good CSV with a bad one (keep the validation and the
  `cmp` / checked `mv` logic exactly).

## Approaches considered

1. **`.command` launcher (picked).** Terminal runs the script, so Terminal's
   existing grant covers the write. Cost: a Terminal window is visible.
2. App hands off to Terminal via AppleScript. Same result, two parts, plus an
   Automation prompt.
3. Import inside MoneyMoney. MoneyMoney cannot import securities; it would
   also need an unzip/xlsx port to Lua and an unproven file write.

## Design

- `sync.sh --wait` (new mode): open the Schwab EAC URL, then wait for an
  `EquityAwardsCenter*.xlsx` in `~/Downloads`. A file modified in the last
  10 minutes counts at once; otherwise poll until one appears (timeout
  15 minutes). Browsers write the final `.xlsx` name only when the download
  is complete, so the glob never sees a partial file. Firefox may first create
  a 0-byte placeholder at the final name; `newest_recent_export` skips
  zero-byte files so the wait is not ended early by a placeholder. Then run the same
  convert / validate / compare / move / refresh logic as the other mode.
- `sync.sh` with no arguments keeps today's behavior (newest export in
  Downloads, no waiting).
- `--from-staging` is removed (only the app used it). The duplicated
  convert/validate/move code becomes one function used by both modes.
- `install.sh` writes `Schwab Sync.command` into the app folder it already
  picks (`/Applications`, else `~/Applications`). The file runs
  `<repo>/sync.sh --wait` with the absolute checkout path. All signing and
  app-building code is removed. If an old `SchwabSync.app` exists, install
  prints a one-time clean-up note (delete the app; optionally delete the
  "SchwabSync Signing" key) and does not delete anything itself.
- Delete `shortcut/` (AppleScript, icon). Remove the `osacompile` check from
  the pre-commit hook. Update README and CLAUDE.md (keep the TCC finding as a
  gotcha so nobody rebuilds the app).
- Test: `tests/test_sync_wait.sh` runs `sync.sh --wait` against a temporary
  `HOME` with the synthetic fixture, with opening the URL and the MoneyMoney
  refresh switched off by one env var (`SCHWAB_SYNC_TEST=1`). It must run on
  macOS and on the Ubuntu CI (portable `find -mmin`, no `open`). Wire it into
  the hook and CI.

## Calls made by the builder (owner may override)

- The Terminal window stays open after the run so the result stays readable;
  closing other Terminal windows by script is too risky.
- Progress and result go to the Terminal window; the separate
  `~/Library/Logs/SchwabSync.log` is no longer written.
