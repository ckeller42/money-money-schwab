# MoneyMoney Schwab Extension

Import Charles Schwab equity awards (RSUs and ESPP) into [MoneyMoney](https://moneymoney-app.com)'s portfolio view on macOS.

[![CI](https://github.com/ckeller42/money-money-schwab/workflows/CI/badge.svg)](https://github.com/ckeller42/money-money-schwab/actions)
![Tests](https://img.shields.io/badge/tests-76_passing-brightgreen)
![Lua](https://img.shields.io/badge/Lua_5.3-MoneyMoney_Extension-2C2D72?logo=lua)
![macOS](https://img.shields.io/badge/macOS-Sonoma%2B-000000?logo=apple)
![Schwab](https://img.shields.io/badge/Charles_Schwab-EAC-00A0DC)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- Parses **Equity Awards Center** Excel (`.xlsx`) exports
- Shows each **RSU vesting lot** with vest date, acquisition price, and gain/loss
- Shows each **ESPP purchase lot** with purchase price and qualified/disqualifying status
- One-click **SchwabSync** app: opens Schwab, syncs data, refreshes MoneyMoney
- `schwab-sync` terminal command for quick syncing
- macOS notification on successful sync

## Requirements

- [MoneyMoney](https://moneymoney-app.com) (macOS)
- A Charles Schwab account with equity awards

## Quick Start

```bash
git clone https://github.com/ckeller42/money-money-schwab.git
cd money-money-schwab
./install.sh
```

The installer will:
1. Install the Lua extension into MoneyMoney
2. Create the data directory inside MoneyMoney's sandbox
3. Build and install **SchwabSync.app** to /Applications
4. Add a `schwab-sync` shell alias
5. Run an initial sync of any EAC `.xlsx` exports in ~/Downloads

### First-time MoneyMoney setup

1. Restart MoneyMoney
2. Hold **Option (⌥)** and click the **Help** menu to enable unsigned extensions
3. **Add Account** → search for **schwab-csv** → click through (leave username/password empty)
4. Refresh the account

## Usage

### Option A: SchwabSync app (recommended)

Open **SchwabSync** from Applications or Spotlight. It will:

1. Open the [Schwab Equity Awards Center](https://client.schwab.com/app/accounts/equityawards/#/equityTodayView) in your browser
2. Show a dialog — download the Equity Details Excel (`.xlsx`) file, then click OK
3. Convert and sync it into MoneyMoney's sandbox
4. Bring MoneyMoney to the front and refresh all accounts automatically
   (requires Accessibility permission for SchwabSync; falls back to a
   "refresh manually" notification without it)

### Option B: Terminal

```bash
# Download Equity Details .xlsx from Schwab EAC, then:
schwab-sync

# Refresh the Schwab account in MoneyMoney (Cmd+R)
```

### Why is there a sync step?

macOS protects `~/Downloads` with TCC (Transparency, Consent, and Control). MoneyMoney runs in a sandbox and cannot read this directory directly. The sync command copies the latest export into MoneyMoney's own data directory where the extension can read it. It also converts the `.xlsx` export to the CSV the extension reads, using only tools built into macOS (`perl`).

## Supported Export Format

| File Pattern | Source | Data |
|---|---|---|
| `EquityAwardsCenter_EquityDetails_*.xlsx` | [Schwab EAC](https://client.schwab.com/app/accounts/equityawards/#/equityTodayView) → Export | RSU lots (per vest date) + ESPP lots (per purchase date) |

`sync.sh` converts the `.xlsx` (a compressed Excel workbook) to CSV via `xlsx2csv`, then the extension auto-detects these sections:
- **Restricted Stock Units** — grant summaries (skipped; per-lot data used instead)
- **Employee Stock Purchase Plan Shares** — individual purchase lots with purchase price and holding period status
- **Equity Award Shares** — individual vesting events with acquisition price

## How It Works

```
Schwab EAC ──Export──▶ ~/Downloads/EquityAwardsCenter_*.xlsx
                              │
                              ▼  schwab-sync (or SchwabSync.app): xlsx2csv converts
        MoneyMoney sandbox: .../Extensions/SchwabData/schwab_eac.csv
                              │
                              ▼  Refresh account (Cmd+R)
                   MoneyMoney portfolio view
                   ├── ACME RSU #123456 2023-03-15   100 shares @ $50.00
                   ├── ACME RSU #123456 2023-06-21    50 shares @ $55.00
                   ├── ACME ESPP 2023-02-28 Q        200 shares @ $42.50
                   └── ...
```

## Project Structure

```
money-money-schwab/
├── extension/
│   └── SchwabPortfolio.lua    # MoneyMoney Web Banking extension (Lua)
├── shortcut/
│   └── SchwabSync.applescript # One-click app source (compiled by install.sh)
├── xlsx2csv                  # Perl: converts EAC .xlsx export to CSV
├── install.sh                 # One-step installer
├── sync.sh                    # Converts latest EAC .xlsx and copies it into MoneyMoney's sandbox
└── README.md
```

## Uninstall

```bash
# Remove the SchwabSync app
rm -rf /Applications/SchwabSync.app

# Remove MoneyMoney extension and data
rm ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/SchwabPortfolio.lua
rm -rf ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/SchwabData/

# Remove shell alias — edit ~/.zshrc (or ~/.bashrc) and delete the schwab-sync line
```

Then remove the Schwab account in MoneyMoney.

## Limitations

- **EAC exports only** — the sync workflow currently handles Equity Awards Center exports. The Lua extension also contains parsers for standard Schwab Positions and Transactions CSVs, but these are not yet wired into `sync.sh`.
- **No live price updates from extension** — prices come from the CSV at export time. MoneyMoney may fetch live quotes if it recognizes the ticker symbol.
- **No automatic download** — you must manually export the .xlsx from Schwab's website. The Schwab Trader API could automate this but requires a developer account and re-authentication every 7 days.
- **Unsigned extension** — MoneyMoney requires you to explicitly enable unsigned extensions.

## Development

### Prerequisites (macOS)

**MacPorts:**
```bash
sudo port install lua shellcheck lua-luacheck lua-luarocks
```

**Homebrew:**
```bash
brew install lua shellcheck luarocks
luarocks --local install luacheck
export PATH="$HOME/.luarocks/bin:$PATH"  # add to ~/.zshrc
```

### Running tests

The extension includes inline self-tests that exercise all CSV parsers, plus a
golden test for the `.xlsx` → CSV converter:

```bash
lua extension/SchwabPortfolio.lua
bash tests/test_xlsx2csv.sh
```

Expected output:
```
76 passed, 0 failed
xlsx2csv: PASS
```

### Running linters

```bash
luacheck extension/SchwabPortfolio.lua
shellcheck install.sh sync.sh
```

### Pre-commit hook

A pre-commit hook runs linters and tests automatically before each commit. It's set up via:

```bash
git config core.hooksPath .githooks
```

The hook is in `.githooks/pre-commit` and will:
1. Run `luacheck` on the Lua extension
2. Run `shellcheck` on shell scripts
3. Run the inline Lua tests

If any check fails, the commit is blocked.

### Reinstalling after code changes

```bash
./install.sh
# Then restart MoneyMoney to pick up the new extension
```

## License

MIT

