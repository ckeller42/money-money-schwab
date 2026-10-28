-- SchwabSync: Schwab EAC download + sync helper
--
-- What it does:
--   1. Opens Schwab Equity Awards Center in your default browser
--   2. Asks user to pick the downloaded .xlsx via file dialog
--   3. Launches MoneyMoney, reads the picked file in-process to /tmp
--   4. Runs sync.sh, which converts, syncs, and refreshes MoneyMoney
--
-- Every step is logged to ~/Library/Logs/SchwabSync.log (paths + step names
-- only, never balances or credentials), and every outcome shows a visible
-- dialog — notifications from this ad-hoc-signed app never appear, so they
-- are useless as a status channel.
--
-- install.sh patches __SYNC_SCRIPT__ at install time.

-- Append one timestamped line to the log. Best-effort: never block the flow.
on logStep(msg)
	try
		set logFile to (POSIX path of (path to home folder)) & "Library/Logs/SchwabSync.log"
		set ts to do shell script "date '+%Y-%m-%d %H:%M:%S'"
		do shell script "printf '%s\\n' " & quoted form of (ts & "  " & msg) & " >> " & quoted form of logFile
	end try
end logStep

logStep("=== SchwabSync started ===")

-- Step 1: Open Schwab EAC
open location "https://client.schwab.com/app/accounts/equityawards/#/equityTodayView"
logStep("Opened Schwab EAC URL")

-- Step 2: Ask user to select the downloaded xlsx.
-- choose file cannot preselect or sort — the dialog follows the Finder sort —
-- so the prompt reminds the user to pick the NEWEST export. The visible
-- "already synced" dialog below catches it if they pick an old one anyway.
set xlsxFile to choose file with prompt ¬
	"Select your Schwab EAC Excel (.xlsx) file — pick the MOST RECENT one (newest date in the filename):" of type ¬
	{"xlsx", "org.openxmlformats.spreadsheetml.sheet"} default location ¬
	(path to downloads folder)
set pickedPath to POSIX path of xlsxFile
set pickedName to do shell script "basename " & quoted form of pickedPath
logStep("Picked file: " & pickedPath)

-- Step 3: Make sure MoneyMoney is running, so sync.sh can refresh it
tell application "MoneyMoney"
	activate
end tell
logStep("Activated MoneyMoney")

-- Step 4: Copy the picked file to a staging copy, reading it IN THIS PROCESS.
-- `choose file` grants only this app process read access to the picked file;
-- a child process (cp) does not inherit that grant, so when the app has no
-- persistent TCC grant for ~/Downloads the copy hangs with no prompt. Reading
-- and writing here uses the grant the picker just gave us.
set stagingDir to do shell script "mktemp -d /tmp/schwab-sync.XXXXXX"
set stagingFile to stagingDir & "/schwab_eac.xlsx"
try
	set inHandle to open for access xlsxFile
	set fileData to read inHandle as data
	close access inHandle
	set outHandle to open for access (POSIX file stagingFile) with write permission
	set eof outHandle to 0
	write fileData to outHandle
	close access outHandle
	do shell script "chmod 600 " & quoted form of stagingFile
	logStep("Staged copy written: " & stagingFile)
on error e number n
	try
		close access xlsxFile
	end try
	try
		close access (POSIX file stagingFile)
	end try
	try
		do shell script "rm -rf " & quoted form of stagingDir
	end try
	logStep("Staging copy FAILED (" & n & "): " & e)
	display dialog "Could not read the selected file: " & e & " (" & n & ")" buttons {"OK"} default button 1 with icon stop with title "Schwab Sync"
	return
end try

-- Step 5: Sync from staging. sync.sh converts, validates, replaces the CSV and
-- refreshes MoneyMoney. Its own notifications are invisible from this app, so
-- every outcome is shown as a dialog here instead.
try
	set syncOutput to do shell script "__SYNC_SCRIPT__ --from-staging " & quoted form of stagingFile
on error e number n
	logStep("Sync FAILED (" & n & "): " & e)
	display dialog "Sync failed:" & return & return & e buttons {"OK"} default button 1 with icon stop with title "Schwab Sync"
	return
end try
logStep("Sync output: " & syncOutput)

if syncOutput contains "Already up to date" then
	display dialog "This file is already synced — MoneyMoney was NOT updated." & return & return & "Picked: " & pickedName & return & return & "If you expected new data, you likely selected an older export. Re-run SchwabSync and pick the file with the newest date." buttons {"OK"} default button 1 with icon caution with title "Schwab Sync"
else
	display dialog "Synced — MoneyMoney is refreshing all accounts." & return & return & "From: " & pickedName buttons {"OK"} default button 1 with title "Schwab Sync"
end if
logStep("=== SchwabSync finished ===")
