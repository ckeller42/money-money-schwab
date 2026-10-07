# money-money-schwab

## Workflow
- **PR-only.** `main` is protected (admins too, CI `lint-and-test` must pass, conversation resolution required). Branch → commit → `gh pr create`. Direct push fails.
- CodeRabbit reviews every PR (`.coderabbit.yaml`). Unresolved threads block merge: fix, then resolve via GraphQL `resolveReviewThread` (or PR UI). Free plan: summary only, ~1 review/hour.
- Bump `version` in `extension/SchwabPortfolio.lua` whenever the extension changes — MoneyMoney only reloads a changed unsigned extension on a version change.

## Test / lint
- `git config core.hooksPath .githooks` once per clone — the pre-commit hook mirrors CI: luacheck, shellcheck, osacompile, `tests/test_xlsx2csv.sh`, Lua self-tests (`lua extension/SchwabPortfolio.lua`), personal-data scan.
- CI (ubuntu) can't run `osacompile`; only the local hook checks the AppleScript.

## Privacy (public repo)
- Fixtures and docs must be synthetic: ACME, award IDs 100001/123456, prices 12.345/23.456. Scanners reject any other 6-digit number or 3-decimal price.
- Never add real values to a scanner blocklist — that leaks them. Never commit real exports, screenshots, or balances.
- GitHub secret scanning + push protection are enabled (repo settings). Push protection blocks only the subset of supported provider token types GitHub marks push-protected; scanning alerts cover more. No custom patterns are configured, so neither knows Schwab data formats — the custom scanner (pre-commit + CI) is the only guard for award IDs, prices, emails, and `/Users/` paths.

## Gotchas
- MoneyMoney re-reads `schwab_eac.csv` only on account refresh; `sync.sh` triggers one via a System Events menu-click (no refresh command in its AppleScript dictionary). Needs Accessibility permission.
- MoneyMoney sandbox: no `io.popen`, no zlib — the `.xlsx` is converted outside the sandbox by `xlsx2csv` (core Perl only, no CPAN).
- Real Schwab exports live in `~/Downloads` and the MoneyMoney container — never copy them into the repo or scratch output that gets committed.
