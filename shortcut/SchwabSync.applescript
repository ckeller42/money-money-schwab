-- SchwabSync: Schwab EAC download + sync helper
--
-- What it does:
--   1. Opens Schwab Equity Awards Center in your default browser
--   2. Asks user to pick the downloaded .xlsx via file dialog
--   3. Launches MoneyMoney, copies the file to /tmp (no TCC restrictions)
--   4. Runs sync.sh, which converts, syncs, and refreshes MoneyMoney
--
-- install.sh patches __SYNC_SCRIPT__ at install time.

-- Step 1: Open Schwab EAC
open location "https://client.schwab.com/app/accounts/equityawards/#/equityTodayView"

-- Step 2: Ask user to select the downloaded xlsx
set xlsxFile to choose file with prompt ¬
	"Select your Schwab EAC Excel (.xlsx) file:" of type ¬
	{"xlsx", "org.openxmlformats.spreadsheetml.sheet"} default location ¬
	(path to downloads folder)

-- Step 3: Make sure MoneyMoney is running, so sync.sh can refresh it
tell application "MoneyMoney"
	activate
end tell

-- Step 4: Copy to secure temp file
set xlsxPosix to POSIX path of xlsxFile
set stagingDir to do shell script "mktemp -d /tmp/schwab-sync.XXXXXX"
set stagingFile to stagingDir & "/schwab_eac.xlsx"
do shell script "cp " & quoted form of xlsxPosix & " " & quoted form of stagingFile & " && chmod 600 " & quoted form of stagingFile

-- Step 5: Sync from staging. sync.sh owns the MoneyMoney refresh and its
-- notification; it only stays silent when nothing changed.
set syncOutput to do shell script "__SYNC_SCRIPT__ --from-staging " & quoted form of stagingFile
if syncOutput contains "Already up to date" then
	display notification "Already up to date — nothing to refresh." with title "Schwab Sync"
end if
