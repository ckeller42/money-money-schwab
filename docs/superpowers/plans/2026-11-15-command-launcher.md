# Command Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SchwabSync.app with a Terminal-run `Schwab Sync.command` that opens Schwab, waits for the new export, and syncs it.

**Architecture:** `sync.sh` gains a `--wait` mode and one shared `sync_xlsx` function; `install.sh` writes a tiny `.command` file that runs `sync.sh --wait` from the checkout. Everything app-related (AppleScript, icon, signing, integrity check, osacompile hook) is deleted.

**Tech Stack:** bash, core Perl (`xlsx2csv`, unchanged), shellcheck, the existing pre-commit hook and GitHub Actions CI (Ubuntu).

**Spec:** `docs/superpowers/specs/2026-11-15-command-launcher-design.md`

## Global Constraints

- No change to `extension/SchwabPortfolio.lua` or `xlsx2csv`.
- Keep the safety order exactly: convert → validate → `cmp` → checked `mv` → refresh. A bad export must never replace the target.
- Fixtures/docs synthetic only. The scanner rejects any standalone 6-digit number other than 100001/123456/000000, any 3-decimal price other than 12.345/23.456, and real `/Users/<name>` paths.
- Shell must pass `shellcheck` and run on macOS bash 3.2 **and** Ubuntu bash (CI). No `open`, `touch -A`, `stat -f`, or GNU-only flags in code the test exercises.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01GWXjZUWPDCeixxLr76xZqf`.
- `git config core.hooksPath .githooks` is set; every commit runs the hook. Never `--no-verify`.

## Review Focus

1. A stale export already in Downloads (older than 10 min) must NOT be synced by `--wait`; it must wait for a new one. → Task 1 test `old_file_is_ignored_then_new_one_synced`.
2. The same file run twice reports "Already up to date" and does not rewrite the target. → Task 1 test `second_run_up_to_date`.
3. A garbage `.xlsx` exits non-zero and leaves the existing target byte-identical. → Task 1 test `bad_export_keeps_target`.
4. No export ever arrives: exits non-zero after the timeout with a clear message, no target created. → Task 1 test `timeout_without_export`.
5. Repo path with spaces: the generated `.command` must quote it. → Task 2 step "verify generated launcher".

---

### Task 1: `sync.sh --wait` mode, shared sync function, test

**Files:**
- Modify: `sync.sh` (whole file; remove `--from-staging` and `cleanup_staging`)
- Create: `tests/test_sync_wait.sh`
- Modify: `.githooks/pre-commit` (add test to shellcheck list; add a `run "sync wait" bash tests/test_sync_wait.sh` check)
- Modify: `.github/workflows/ci.yml` (add test to shellcheck list; add step "Run sync --wait test": `bash tests/test_sync_wait.sh`)

**Interfaces:**
- Produces (CLI): `sync.sh` (no args: newest `~/Downloads/EquityAwardsCenter*.xlsx`, unchanged behavior) and `sync.sh --wait`. Exit 0 on synced or already-up-to-date, non-zero on any failure.
- Produces (env): `SCHWAB_SYNC_TEST=1` disables `open`, every `osascript` call, and the MoneyMoney refresh. `SCHWAB_SYNC_WAIT_SECS` overrides the wait timeout (default `900`).
- Produces (internal): `sync_xlsx <xlsx-path>` — convert, validate, compare, move, refresh; prints `✓ Synced: <basename>` or `Already up to date: <basename>`; returns non-zero on failure. `newest_recent_export <minutes>` — prints the newest `EquityAwardsCenter*.xlsx` in `$HOME/Downloads` with mtime within `<minutes>` (via `find -maxdepth 1 -mmin -N`), or nothing.

- [ ] **Step 1: Write the failing test `tests/test_sync_wait.sh`**

  Style like `tests/test_xlsx2csv.sh` (`set -e`, `DIR` = repo root, print `PASS`/`FAIL` per case, `exit 1` on any failure). Each case uses a fresh `HOME=$(mktemp -d)` with `mkdir -p "$HOME/Downloads"`, runs `SCHWAB_SYNC_TEST=1 HOME=... bash "$DIR/sync.sh" --wait`, and checks
  `TARGET="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/SchwabData/schwab_eac.csv"`.
  Compare content as `[ "$(cat "$TARGET")" = "$(cat "$DIR/tests/fixtures/expected_eac.csv")" ]`. Cases:
  - `recent_file_synced_immediately`: copy `tests/fixtures/sample_eac.xlsx` to `Downloads/EquityAwardsCenter_EquityDetails_test.xlsx`; exit 0; output contains `✓ Synced`; target equals expected.
  - `second_run_up_to_date`: run again on the same HOME; exit 0; output contains `Already up to date`.
  - `bad_export_keeps_target`: after a good sync, replace the Downloads file with `printf garbage`; exit non-zero; target still equals expected.
  - `old_file_is_ignored_then_new_one_synced`: fixture copied as `EquityAwardsCenter_old.xlsx` with `touch -t 200001010000`; start `sync.sh --wait` with `SCHWAB_SYNC_WAIT_SECS=20`; in background after `sleep 3` copy the fixture as `EquityAwardsCenter_new.xlsx`; exit 0; output names `EquityAwardsCenter_new.xlsx`.
  - `timeout_without_export`: empty Downloads, `SCHWAB_SYNC_WAIT_SECS=3`; exit non-zero; output contains `No new EquityAwardsCenter`; target does not exist.

- [ ] **Step 2: Run it, verify it fails**

  Run: `bash tests/test_sync_wait.sh`
  Expected: FAIL (`--wait` is unknown; current script treats it as no-arg mode or errors).

- [ ] **Step 3: Implement in `sync.sh`**

  - Extract `sync_xlsx` from the duplicated branches; keep its messages (`✗ Failed to convert …`, `✗ CSV validation failed: …`, `✗ Keeping existing data — … doesn't look like a Schwab EAC export`, `✗ Failed to replace target CSV`).
  - Guard `refresh_moneymoney` and the `osascript` notification in `validate_csv` with `SCHWAB_SYNC_TEST`.
  - `--wait`: unless test mode, `open "https://client.schwab.com/app/accounts/equityawards/#/equityTodayView"` and print `Download the Equity Details Excel (.xlsx) from Schwab — waiting for it in ~/Downloads…`. Then loop every 2 s: `newest_recent_export $((10 + elapsed/60 + 1))`; a hit → `sync_xlsx` and exit with its status. On timeout print `✗ No new EquityAwardsCenter*.xlsx arrived in ~/Downloads within N minutes` and exit 1.
  - Header comment: document both modes and the env vars; remove every SchwabSync.app mention.

- [ ] **Step 4: Run tests and lint**

  Run: `bash tests/test_sync_wait.sh && shellcheck sync.sh tests/test_sync_wait.sh`
  Expected: all five cases `PASS`, shellcheck silent.

- [ ] **Step 5: Wire into hook and CI, commit**

  Add the hook/CI entries listed under Files. Then:
  ```bash
  git add sync.sh tests/test_sync_wait.sh .githooks/pre-commit .github/workflows/ci.yml
  git commit -m "feat: sync.sh --wait opens Schwab and syncs the new export"
  ```
  Expected: hook prints `sync wait... ok` and `All checks passed.`

### Task 2: launcher in `install.sh`; remove the app; docs

**Files:**
- Modify: `install.sh` (delete lines for signing identity + app build, i.e. the `stable code-signing identity` and `build and install SchwabSync app` sections; replace the closing notes)
- Delete: `shortcut/SchwabSync.applescript`, `shortcut/SchwabSync.icns` (`git rm`)
- Modify: `.githooks/pre-commit` (remove the `osacompile` block)
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: `sync.sh --wait` from Task 1.
- Produces: `$APP_DIR/Schwab Sync.command` (mode 755) with exactly:
  ```bash
  #!/bin/bash
  exec "<absolute SCRIPT_DIR>/sync.sh" --wait
  ```
  written with `printf` so `SCRIPT_DIR` is quoted correctly even with spaces.

- [ ] **Step 1: Rewrite `install.sh`**

  Keep: paths, preflight, extension install, data dir, alias hint, initial sync. Add the launcher write (above). If `$APP_DIR/SchwabSync.app` exists, print:
  `Old SchwabSync.app found. It can't sync on current macOS — delete it (rm -rf "$APP_DIR/SchwabSync.app"). Optional: delete the "SchwabSync Signing" key in Keychain Access.` Never delete it. Replace "Next steps" item 4 with: `Double-click "Schwab Sync" in $APP_DIR (or find it with Spotlight) — Terminal opens Schwab and syncs your new download.` Remove the "data from other apps" note.

- [ ] **Step 2: Verify the generated launcher (Review Focus 5)**

  Run (does not touch the real system):
  ```bash
  T=$(mktemp -d "/tmp/repo with space.XXXX"); cp -R . "$T/"; \
  sed -n '/Schwab Sync.command/,+3p' "$T/install.sh"
  ```
  then extract and run only the launcher-writing lines with `APP_DIR=$(mktemp -d)` and `SCRIPT_DIR="$T"`, and check: `bash -n "$APP_DIR/Schwab Sync.command"`, `[ -x … ]`, and `grep -F "\"$T/sync.sh\" --wait"` matches. Expected: all three succeed. Do NOT run the full `./install.sh`.

- [ ] **Step 3: Delete the app sources and the hook check**

  `git rm shortcut/SchwabSync.applescript shortcut/SchwabSync.icns`; remove the `# AppleScript syntax check` block from `.githooks/pre-commit`.

- [ ] **Step 4: Update docs**

  - README: Features (one-click **Schwab Sync** launcher instead of the app; keep the notification line — Terminal runs still notify), Quick Start installer list item 3, Usage "Option A" (double-click `Schwab Sync`, Terminal opens Schwab, waits for the download, syncs; needs Accessibility for Terminal for the auto-refresh, as Option B already says), How It Works line, Project Structure (drop `shortcut/`, add `tests/test_sync_wait.sh`), Uninstall (`rm "/Applications/Schwab Sync.command"`; old app + key removal), pre-commit list.
  - CLAUDE.md: Test/lint line drops `osacompile`, adds `tests/test_sync_wait.sh`; remove the "CI can't run osacompile" sentence's AppleScript part; replace the two SchwabSync.app gotchas with one: *Writing into MoneyMoney's container is gated by `kTCCServiceSystemPolicyAppDataDetailed`; macOS denies it for a self-signed app with no dialog even with Full Disk Access and after `tccutil reset` (tested 2026-11-15). Terminal holds the grant, so the sync runs in Terminal via `Schwab Sync.command`. Do not rebuild a GUI app for this.*

- [ ] **Step 5: Full check and commit**

  Run: `.githooks/pre-commit` (with staged changes) and `git grep -nE "SchwabSync\.app|applescript|osacompile|from-staging"`
  Expected: hook `All checks passed.`; grep hits only the CLAUDE.md gotcha, the install.sh old-app note, and README uninstall/clean-up lines.
  ```bash
  git add -A install.sh README.md CLAUDE.md .githooks/pre-commit shortcut
  git commit -m "feat: replace SchwabSync.app with a Terminal .command launcher"
  ```
