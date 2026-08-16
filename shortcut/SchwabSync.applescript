-- SchwabSync: Schwab EAC download + sync helper
--
-- What it does:
--   1. Opens Schwab Equity Awards Center in your default browser
--   2. Asks user to pick the downloaded .xlsx via file dialog
--   3. Copies it to /tmp (no TCC restrictions)
--   4. Reminds user to run schwab-sync
--
-- install.sh patches __SYNC_SCRIPT__ at install time.

-- Step 1: Open Schwab EAC
open location "https://client.schwab.com/app/accounts/equityawards/#/equityTodayView"

-- Step 2: Ask user to select the downloaded xlsx
set xlsxFile to choose file with prompt ¬
	"Select your Schwab EAC Excel (.xlsx) file:" of type ¬
	{"xlsx", "org.openxmlformats.spreadsheetml.sheet"} default location ¬
	(path to downloads folder)

-- Step 3: Copy to secure temp file and sync
set xlsxPosix to POSIX path of xlsxFile
set stagingDir to do shell script "mktemp -d /tmp/schwab-sync.XXXXXX"
set stagingFile to stagingDir & "/schwab_eac.xlsx"
do shell script "cp " & quoted form of xlsxPosix & " " & quoted form of stagingFile & " && chmod 600 " & quoted form of stagingFile

-- Step 4: Run sync from staging
do shell script "__SYNC_SCRIPT__ --from-staging " & quoted form of stagingFile

-- Step 5: Activate MoneyMoney and trigger a refresh of all accounts.
-- Menu-click via System Events because MoneyMoney's AppleScript dictionary
-- has no refresh command. Needs Accessibility permission for SchwabSync.app
-- (System Settings → Privacy & Security → Accessibility) — if not granted,
-- we fall back to asking the user to refresh manually.
tell application "MoneyMoney"
	activate
end tell
delay 1

set refreshTriggered to false
tell application "System Events"
	tell process "MoneyMoney"
		repeat with menuName in {"Ablage", "File"} -- German / English UI
			try
				click menu item 1 of menu 1 of menu bar item (menuName as text) of menu bar 1
				set refreshTriggered to true
				exit repeat
			end try
		end repeat
	end tell
end tell

if refreshTriggered then
	display notification "Synced! Accounts are refreshing." with title "Schwab Sync"
else
	display notification "Synced! Refresh your Schwab account (⌘R)." with title "Schwab Sync"
end if
