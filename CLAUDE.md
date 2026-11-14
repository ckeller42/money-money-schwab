# money-money-schwab

## Workflow
- **PR-only.** `main` is protected (admins too, CI `lint-and-test` must pass, conversation resolution required). Branch → commit → `gh pr create`. Direct push fails.
- CodeRabbit reviews every PR (`.coderabbit.yaml`). Unresolved threads block merge: fix, then resolve via GraphQL `resolveReviewThread` (or PR UI). Free plan: summary only, ~1 review/hour.
- Bump `version` in `extension/SchwabPortfolio.lua` whenever the extension changes — MoneyMoney only reloads a changed unsigned extension on a version change.

## Test / lint
- `git config core.hooksPath .githooks` once per clone — the pre-commit hook mirrors CI: luacheck, shellcheck, osacompile, `tests/test_xlsx2csv.sh`, Lua self-tests (`lua extension/SchwabPortfolio.lua`), `tests/test_check_personal_data.sh`, personal-data scan. A missing tool prints `SKIPPED: <tool> not installed` (fails under `CI_STRICT=1`).
- The personal-data scan is ONE script, `tools/check_personal_data.sh` (CI: all tracked files; hook: `--staged`). On a hit it prints `file:line` + rule name, never the value. Edit patterns there only.
- CI (ubuntu) can't run `osacompile`; only the local hook checks the AppleScript. `workflow-lint.yml` (actionlint + zizmor) is a separate, non-required check.

## Privacy (public repo)
- Fixtures and docs must be synthetic: ACME, award IDs 100001/123456, prices 12.345/23.456. Scanners reject any other 6-digit number or 3-decimal price.
- Never add real values to a scanner blocklist — that leaks them. Never commit real exports, screenshots, or balances.
- GitHub secret scanning + push protection are enabled (repo settings). Push protection blocks only the subset of supported provider token types GitHub marks push-protected; scanning alerts cover more. No custom patterns are configured, so neither knows Schwab data formats — the custom scanner `tools/check_personal_data.sh` (pre-commit + CI) is the only guard for award IDs, prices, emails, and `/Users/` paths.

## Gotchas
- MoneyMoney re-reads `schwab_eac.csv` only on account refresh; `sync.sh` triggers one via a System Events menu-click (no refresh command in its AppleScript dictionary). Needs Accessibility permission.
- MoneyMoney sandbox: no `io.popen`, no zlib — the `.xlsx` is converted outside the sandbox by `xlsx2csv` (core Perl only, no CPAN).
- Second TCC wall: writing the CSV into MoneyMoney's container (`~/Library/Containers/com.moneymoney-app.retail/Data/…`) needs a TCC grant ("data from other apps" / Full Disk Access). An ad-hoc app's grant is keyed to its cdhash and is lost on every rebuild, so `install.sh` signs SchwabSync.app with a stable self-signed identity (`io.github.ckeller42.schwabsync`, cert CN `SchwabSync Signing`, created once in the login keychain) — the designated requirement is then cdhash-independent and the grant survives reinstalls. Terminal/`schwab-sync` works without this because Terminal already holds the grant.
- SchwabSync.app runs its **own bundled** `sync.sh` + `xlsx2csv` from `Contents/Resources` (copied in and signed by `install.sh`), not the repo checkout — a signed app holding a file-access grant must not execute a user-writable script. Before running them the applet does `codesign --verify --strict` on itself and aborts on failure; a tampered bundled script breaks the seal, and the grant is keyed to the signing identity, so a re-signed copy loses it. The applet resolves its own path at runtime (no `__SYNC_SCRIPT__` patching). The signing key is imported **non-pre-authorized** (no `codesign` in `-T`, `-x` non-extractable), so every `codesign` use prompts — a background same-user process can't silently re-sign a tampered bundle and keep the grant. Tell users to click **Allow**, not "Always Allow".
- Real Schwab exports live in `~/Downloads` and the MoneyMoney container — never copy them into the repo or scratch output that gets committed.

## Dependabot

`.github/workflows/dependabot-auto-merge.yml` squash-merges a Dependabot PR once CI has passed on its exact head commit, but only when no bumped dependency is a semver major (it reads the `update-type` trailers; a grouped PR waits if any member is major). It does not rely on the repo's "Allow auto-merge" setting. Major bumps and anything CI rejects stay open for review. It also skips PRs without an `update-type` trailer and PRs with a commit not authored by Dependabot. A merge made with the workflow's token does not start `push` workflows, so CI does not re-run on `main` afterwards; run it by hand if a bump needs it.
