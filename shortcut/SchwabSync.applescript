-- SchwabSync: Schwab EAC download + sync helper
--
-- What it does:
--   1. Opens Schwab Equity Awards Center in your default browser
--   2. Asks user to pick the downloaded .xlsx via file dialog
--   3. Launches MoneyMoney, reads the picked file in-process to /tmp
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
on error e number n
	try
		close access xlsxFile
	end try
	display dialog "Could not read the selected file: " & e & " (" & n & ")" buttons {"OK"} default button 1 with icon stop with title "Schwab Sync"
	return
end try

-- Step 5: Sync from staging. sync.sh owns the MoneyMoney refresh and its
-- notification; it only stays silent when nothing changed.
set syncOutput to do shell script "__SYNC_SCRIPT__ --from-staging " & quoted form of stagingFile
if syncOutput contains "Already up to date" then
	display notification "Already up to date — nothing to refresh." with title "Schwab Sync"
end if
