-- MoneyMoney Web Banking Extension: Charles Schwab Portfolio
-- Reads Schwab CSV files from the SchwabData folder next to this extension.
--
-- Supported data (auto-detected):
--   - Equity Awards Center export (RSU + ESPP) — Schwab exports this as .xlsx;
--     sync.sh converts it to CSV via xlsx2csv before this extension reads it
--   - Standard Positions CSV
--   - Standard Transactions CSV
--
-- Usage:
--   1. Run sync.sh to convert/copy the latest Schwab export into MoneyMoney's sandbox
--   2. Refresh the account in MoneyMoney
--
-- Install: copy this file to
--   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/

-- Stub MoneyMoney globals when running outside MoneyMoney (e.g. tests)
if not WebBanking then
  WebBanking = function() end
  ProtocolWebBanking = "ProtocolWebBanking"
  AccountTypePortfolio = "AccountTypePortfolio"
end

WebBanking{
  version     = 1.8,
  url         = "https://www.schwab.com",
  description = "Import Charles Schwab positions, RSUs & ESPP from Schwab exports",
  services    = {"schwab-csv"},
}

local function log(msg)
  print("[SchwabCSV] " .. tostring(msg))
end

-- ISIN lookup for common US equities. Helps MoneyMoney match live quotes.
-- Add more tickers here as needed.
local ISIN = {
  NVDA = "US67066G1040",
  AAPL = "US0378331005",
  MSFT = "US5949181045",
  GOOG = "US02079K3059",
  GOOGL = "US02079K1079",
  AMZN = "US0231351067",
  META = "US30303M1027",
  TSLA = "US88160R1014",
  INTC = "US4581401001",
  AMD  = "US0079031078",
}

-- ---------------------------------------------------------------------------
-- Data directory discovery
-- ---------------------------------------------------------------------------

local KNOWN_FILES = {
  eac          = "schwab_eac.csv",
  positions    = "schwab_positions.csv",
  transactions = "schwab_transactions.csv",
}

-- Path to synced CSV data. install.sh replaces __HOME__ at install time.
-- If you installed manually, replace __HOME__ with e.g. /Users/yourname.
local DATA_DIR = "__HOME__/Library/Containers/com.moneymoney-app.retail"
  .. "/Data/Library/Application Support/MoneyMoney/Extensions/SchwabData/"

local function getDataDir()
  return DATA_DIR
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- ---------------------------------------------------------------------------
-- CSV parsing utilities
-- ---------------------------------------------------------------------------

local function parseCsvLine(line)
  local fields = {}
  local i = 1
  while i <= #line do
    if line:sub(i, i) == '"' then
      local j = i + 1
      local value = ""
      while j <= #line do
        if line:sub(j, j) == '"' then
          if line:sub(j + 1, j + 1) == '"' then
            value = value .. '"'
            j = j + 2
          else
            j = j + 1
            break
          end
        else
          value = value .. line:sub(j, j)
          j = j + 1
        end
      end
      fields[#fields + 1] = value
      if line:sub(j, j) == "," then j = j + 1 end
      i = j
    elseif line:sub(i, i) == "," then
      fields[#fields + 1] = ""
      i = i + 1
    else
      local j = line:find(",", i)
      if j then
        fields[#fields + 1] = line:sub(i, j - 1)
        i = j + 1
      else
        fields[#fields + 1] = line:sub(i)
        i = #line + 1
      end
    end
  end
  return fields
end

local function splitLines(text)
  local lines = {}
  for line in text:gmatch("([^\r\n]+)") do
    lines[#lines + 1] = line
  end
  return lines
end

local function parseMoney(str)
  if not str or str == "" or str == "--" then return nil end
  local s = (str:gsub("%$", "")):gsub(",", "")
  return tonumber(s)
end

local function parseQuantity(str)
  if not str or str == "" or str == "--" then return nil end
  local s = (str:gsub(",", "")):gsub('"', "")
  return tonumber(s)
end

-- Parse dates in "MM/DD/YYYY" or "MM-DD-YYYY" format.
-- Also handles "MM/DD/YYYY as of MM/DD/YYYY" (uses the first date).
local function parseDateMDY(str)
  if not str or str == "" then return nil end
  str = (str:gsub('"', ""))
  local m, d, y = str:match("(%d+)[/%-](%d+)[/%-](%d+)")
  if not m then return nil end
  return os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12})
end

-- "MM-DD-YYYY" or "MM/DD/YYYY" → "YYYY-MM-DD"
local function formatDateISO(str)
  if not str then return "unknown" end
  str = (str:gsub('"', ""))
  local m, d, y = str:match("(%d+)[/%-](%d+)[/%-](%d+)")
  if not m then return str end
  return string.format("%s-%02d-%02d", y, tonumber(m), tonumber(d))
end

local function isDataRow(fields)
  return fields[1] and fields[1]:match("^%d")
end

local function isHeaderRow(fields)
  if not fields[1] then return false end
  local f = fields[1]:lower()
  return f:match("^award") or f:match("^purchase") or f:match("^date")
      or f:match("^symbol") or f:match("^totals")
end

-- Build a header-name → column-index map from a parsed header row.
local function buildHeaderMap(fields)
  local map = {}
  for idx, name in ipairs(fields) do
    local key = name:match("^%s*(.-)%s*$")
    if key ~= "" then map[key] = idx end
  end
  return map
end

-- Warn loudly if Schwab renamed a column we depend on. Without this, a rename
-- would silently skip every lot AND disarm the Totals cross-check (which reads
-- the same map), so nothing else would catch it.
local function checkRequiredColumns(map, required, sectionName)
  for _, name in ipairs(required) do
    if not map[name] then
      log("WARNING: EAC " .. sectionName .. " header is missing column '"
        .. name .. "' — Schwab format changed? Lots may be skipped.")
    end
  end
end

local ESPP_REQUIRED_COLUMNS = {
  "Purchase Date", "Symbol", "Market Value", "Purchase Price",
  "Date Holding Period Met", "Available to Sell", "Subscription Date",
}
local EA_REQUIRED_COLUMNS = {
  "Award Date", "Symbol", "Award ID", "Market Value",
  "Date Acquired", "Acquisition Price", "Available to Sell",
}

-- ---------------------------------------------------------------------------
-- Consistency checks
-- ---------------------------------------------------------------------------

local function checkSecurity(sec, lineNum)
  if not sec.quantity or sec.quantity <= 0 then
    log("WARN line " .. lineNum .. ": invalid quantity " .. tostring(sec.quantity) .. " for " .. sec.name)
    return false
  end
  if not sec.price or sec.price < 0 then
    log("WARN line " .. lineNum .. ": invalid price " .. tostring(sec.price) .. " for " .. sec.name)
    return false
  end
  if sec.amount and sec.price and sec.quantity then
    local computed = sec.price * sec.quantity
    local diff = math.abs(computed - sec.amount)
    -- Allow up to $1 rounding tolerance
    if diff > 1 then
      log("WARN line " .. lineNum .. ": price*qty=$" .. string.format("%.2f", computed)
        .. " vs market_value=$" .. string.format("%.2f", sec.amount)
        .. " (diff=$" .. string.format("%.2f", diff) .. ") for " .. sec.name)
    end
  end
  if sec.purchasePrice and sec.purchasePrice < 0 then
    log("WARN line " .. lineNum .. ": negative purchase price $"
      .. string.format("%.2f", sec.purchasePrice) .. " for " .. sec.name)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Parse Equity Awards Center CSV
-- One security line per vesting event (RSU) or purchase lot (ESPP).
-- ---------------------------------------------------------------------------

local function parseEac(content)
  local lines = splitLines(content)
  local securities = {}
  local totalValue = 0
  local section = nil
  local lotCount = 0
  local skippedCount = 0

  -- Capture Totals rows for format-change detection
  local expectedTotals = {}  -- section → {shares=N, value=N}
  local headerMaps = {}      -- section → { headerName = colIndex }

  local i = 1
  while i <= #lines do
    local line = lines[i]
    local trimmed = line:match("^%s*(.-)%s*$")

    -- Section headers use *** TITLE *** markers
    if trimmed:match("%*%*%*.*RESTRICTED STOCK UNITS.*%*%*%*") then
      section = "rsu_summary"
      i = i + 1
      goto continue
    elseif trimmed:match("%*%*%*.*EMPLOYEE STOCK PURCHASE PLAN.*%*%*%*") then
      section = "espp"
      i = i + 1
      goto continue
    elseif trimmed:match("%*%*%*.*EQUITY AWARD SHARES.*%*%*%*") then
      section = "equity_awards"
      i = i + 1
      goto continue
    elseif trimmed:match("^Vesting Schedules") or trimmed:match("^Past Vestings") then
      section = "vesting"
      i = i + 1
      goto continue
    elseif trimmed:match("^Totals") then
      -- Parse the Totals row to get Schwab's expected values. The total sits in
      -- the section's "Available to Sell" column, located via the header map.
      local totFields = parseCsvLine(trimmed)
      if section == "espp" and headerMaps.espp then
        expectedTotals.espp_shares =
          parseQuantity(totFields[headerMaps.espp["Available to Sell"]])
      elseif section == "equity_awards" and headerMaps.equity_awards then
        expectedTotals.ea_shares =
          parseQuantity(totFields[headerMaps.equity_awards["Available to Sell"]])
      end
      i = i + 1
      goto continue
    elseif trimmed == "" then
      i = i + 1
      goto continue
    elseif trimmed:match("^Please exercise") then
      break
    end

    local fields = parseCsvLine(line)

    -- Capture the section's header row into a name → index map, then skip it.
    if isHeaderRow(fields) then
      if section == "espp" and not headerMaps.espp then
        headerMaps.espp = buildHeaderMap(fields)
        checkRequiredColumns(headerMaps.espp, ESPP_REQUIRED_COLUMNS, "ESPP")
      elseif section == "equity_awards" and not headerMaps.equity_awards then
        headerMaps.equity_awards = buildHeaderMap(fields)
        checkRequiredColumns(headerMaps.equity_awards, EA_REQUIRED_COLUMNS, "Equity Awards")
      end
      i = i + 1
      goto continue
    end
    if not isDataRow(fields) then
      i = i + 1
      goto continue
    end

    if section == "espp" then
      -- One row per purchase lot. Columns resolved by header name so a future
      -- Schwab reorder does not silently misparse.
      local hm = headerMaps.espp
      if not hm then i = i + 1; goto continue end
      local function col(name) return fields[hm[name]] end

      local purchaseDate     = col("Purchase Date")
      local symbol           = col("Symbol")
      local marketValue      = parseMoney(col("Market Value"))
      local purchasePrice    = parseMoney(col("Purchase Price"))
      local holdingMet       = col("Date Holding Period Met")
      local available        = parseQuantity(col("Available to Sell"))
      local subscriptionDate = col("Subscription Date")

      if available and available > 0 and symbol then
        local lotDate = formatDateISO(purchaseDate)
        local currentPrice = marketValue and (marketValue / available) or nil
        local isQualified = (holdingMet == "Qualified")
        local holdingNote = isQualified and " Q" or " DQ"

        -- Extra metadata to identify the lot
        local details = {}
        if subscriptionDate and subscriptionDate ~= "" then
          details[#details + 1] = "Sub " .. formatDateISO(subscriptionDate)
        end
        if not isQualified and holdingMet and holdingMet ~= "" then
          details[#details + 1] = "Qual " .. formatDateISO(holdingMet)
        end

        local displayName = symbol .. " ESPP " .. lotDate .. holdingNote
        if #details > 0 then
          displayName = displayName .. " | " .. table.concat(details, " | ")
        end

        local sec = {
          name                       = displayName,
          isin                       = ISIN[symbol],
          securityNumber             = symbol .. "-ESPP-" .. lotDate,
          quantity                   = available,
          purchasePrice              = purchasePrice,
          currencyOfPurchasePrice    = "USD",
          price                      = currentPrice,
          currencyOfPrice            = "USD",
          amount                     = marketValue,
          market                     = "Schwab EAC",
          tradeTimestamp             = parseDateMDY(purchaseDate),
        }

        if checkSecurity(sec, i) then
          securities[#securities + 1] = sec
          totalValue = totalValue + (marketValue or 0)
          lotCount = lotCount + 1
        else
          skippedCount = skippedCount + 1
        end
      end

    elseif section == "equity_awards" then
      -- One row per vesting lot. Columns resolved by header name.
      local hm = headerMaps.equity_awards
      if not hm then i = i + 1; goto continue end
      local function col(name) return fields[hm[name]] end

      local awardDate    = col("Award Date")
      local symbol       = col("Symbol")
      local awardId      = col("Award ID")
      local marketValue  = parseMoney(col("Market Value"))
      local dateAcquired = col("Date Acquired")
      local acqPrice     = parseMoney(col("Acquisition Price"))
      local available    = parseQuantity(col("Available to Sell"))

      if available and available > 0 and symbol then
        local lotDate = formatDateISO(dateAcquired)
        local currentPrice = marketValue and (marketValue / available) or nil

        -- Grant date links the vest lot back to the original RSU award
        local details = {}
        if awardDate then
          details[#details + 1] = "Grant " .. formatDateISO(awardDate)
        end

        local displayName = symbol .. " RSU #" .. (awardId or "") .. " " .. lotDate
        if #details > 0 then
          displayName = displayName .. " | " .. table.concat(details, " | ")
        end

        local sec = {
          name                       = displayName,
          isin                       = ISIN[symbol],
          securityNumber             = symbol .. "-RSU-" .. (awardId or "") .. "-" .. lotDate,
          quantity                   = available,
          purchasePrice              = acqPrice,
          currencyOfPurchasePrice    = "USD",
          price                      = currentPrice,
          currencyOfPrice            = "USD",
          amount                     = marketValue,
          market                     = "Schwab EAC",
          tradeTimestamp             = parseDateMDY(dateAcquired),
        }

        if checkSecurity(sec, i) then
          securities[#securities + 1] = sec
          totalValue = totalValue + (marketValue or 0)
          lotCount = lotCount + 1
        else
          skippedCount = skippedCount + 1
        end
      end
    end

    i = i + 1
    ::continue::
  end

  -- Sort by date, newest first
  table.sort(securities, function(a, b)
    return (a.tradeTimestamp or 0) > (b.tradeTimestamp or 0)
  end)

  -- Format-change detection: compare our parsed totals against Schwab's Totals rows.
  -- If they don't match, the CSV format may have changed and we're misparsing data.
  local parsedEsppShares = 0
  local parsedEaShares = 0
  for _, sec in ipairs(securities) do
    if sec.securityNumber:match("ESPP") then
      parsedEsppShares = parsedEsppShares + sec.quantity
    else
      parsedEaShares = parsedEaShares + sec.quantity
    end
  end

  if expectedTotals.espp_shares and expectedTotals.espp_shares ~= parsedEsppShares then
    log("WARNING: ESPP share count mismatch! Parsed "
      .. parsedEsppShares .. " but CSV Totals says "
      .. expectedTotals.espp_shares
      .. ". The CSV format may have changed.")
  end
  if expectedTotals.ea_shares and expectedTotals.ea_shares ~= parsedEaShares then
    log("WARNING: Equity Award share count mismatch! Parsed "
      .. parsedEaShares .. " but CSV Totals says "
      .. expectedTotals.ea_shares
      .. ". The CSV format may have changed.")
  end

  log("EAC: " .. lotCount .. " lots, " .. skippedCount .. " skipped, total $" .. string.format("%.2f", totalValue))
  return securities, totalValue
end

-- ---------------------------------------------------------------------------
-- Parse standard Schwab Positions CSV
-- ---------------------------------------------------------------------------

local function parsePositions(content)
  local lines = splitLines(content)
  local securities = {}
  local cashBalance = 0
  local totalValue = 0

  local headerIdx = nil
  for idx, line in ipairs(lines) do
    if line:match('^"Symbol"') then
      headerIdx = idx
      break
    end
  end
  if not headerIdx then return securities, cashBalance, totalValue end

  for idx = headerIdx + 1, #lines do
    local fields = parseCsvLine(lines[idx])
    local symbol = fields[1]
    if not symbol or symbol == "" then goto continue end

    if symbol == "Account Total" then
      totalValue = parseMoney(fields[7]) or 0
      goto continue
    end
    if symbol == "Cash & Cash Investments" then
      cashBalance = parseMoney(fields[7]) or 0
      goto continue
    end

    local quantity = parseQuantity(fields[3])
    local price = parseMoney(fields[4])
    local marketValue = parseMoney(fields[7])
    local costBasis = parseMoney(fields[10])

    if quantity and quantity > 0 then
      local sec = {
        name                       = fields[2] or symbol,
        isin                       = ISIN[symbol],
        securityNumber             = symbol,
        quantity                   = quantity,
        price                      = price,
        currencyOfPrice            = "USD",
        purchasePrice              = costBasis and quantity > 0 and (costBasis / quantity) or nil,
        currencyOfPurchasePrice    = "USD",
        amount                     = marketValue,
        market                     = "Schwab",
        tradeTimestamp             = os.time(),
      }

      if checkSecurity(sec, idx) then
        securities[#securities + 1] = sec
      end
    end
    ::continue::
  end

  -- Verify: sum of security amounts + cash should ≈ totalValue
  if totalValue > 0 then
    local summed = cashBalance
    for _, sec in ipairs(securities) do
      summed = summed + (sec.amount or 0)
    end
    local diff = math.abs(summed - totalValue)
    if diff > 1 then
      log("WARN positions: sum of parts=$" .. string.format("%.2f", summed)
        .. " vs Account Total=$" .. string.format("%.2f", totalValue)
        .. " (diff=$" .. string.format("%.2f", diff) .. ")")
    end
  end

  return securities, cashBalance, totalValue
end

-- ---------------------------------------------------------------------------
-- Parse standard Schwab Transactions CSV
-- ---------------------------------------------------------------------------

local function parseTransactions(content)
  local lines = splitLines(content)
  local transactions = {}

  local headerIdx = nil
  for idx, line in ipairs(lines) do
    if line:match('^"Date"') then
      headerIdx = idx
      break
    end
  end
  if not headerIdx then return transactions end

  for idx = headerIdx + 1, #lines do
    local fields = parseCsvLine(lines[idx])
    local dateStr = fields[1]
    if not dateStr or dateStr == "" or dateStr == "Transactions Total" then goto continue end

    local bookingDate = parseDateMDY(dateStr)
    if not bookingDate then goto continue end

    local action   = fields[2] or ""
    local symbol   = fields[3] or ""
    local desc     = fields[4] or ""
    local quantity = parseQuantity(fields[5])
    local price    = parseMoney(fields[6])
    local amount   = parseMoney(fields[8])

    if amount then
      local purpose = action
      if symbol ~= "" then purpose = purpose .. " " .. symbol end
      if quantity then
        purpose = purpose .. " (" .. quantity .. " shares"
        if price then purpose = purpose .. " @ $" .. string.format("%.2f", price) end
        purpose = purpose .. ")"
      end

      transactions[#transactions + 1] = {
        name        = desc,
        amount      = amount,
        currency    = "USD",
        bookingDate = bookingDate,
        purpose     = purpose,
        bookingText = action,
        comment     = symbol,
        booked      = true,
      }
    end
    ::continue::
  end

  return transactions
end

-- ---------------------------------------------------------------------------
-- MoneyMoney Web Banking API
-- ---------------------------------------------------------------------------

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "schwab-csv"
end

function InitializeSession2(_protocol, _bankCode, step, _credentials, _interactive)
  if step == 1 then
    local dir = getDataDir()
    if not dir then
      return "SchwabData folder not found. Run sync.sh first to copy CSVs into MoneyMoney."
    end

    local found = {}
    for key, fname in pairs(KNOWN_FILES) do
      if fileExists(dir .. fname) then
        found[#found + 1] = key
        log("Found: " .. fname)
      end
    end

    if #found == 0 then
      return "No Schwab CSV files found in SchwabData folder.\nRun sync.sh to copy your latest exports from Downloads."
    end
  end
end

function ListAccounts(_knownAccounts)
  local accounts = {}
  local dir = getDataDir()
  if not dir then return accounts end

  if fileExists(dir .. KNOWN_FILES.eac) then
    accounts[#accounts + 1] = {
      name          = "Schwab Equity Awards",
      accountNumber = "EAC",
      subAccount    = "eac",
      currency      = "USD",
      portfolio     = true,
      type          = AccountTypePortfolio,
    }
  end

  if fileExists(dir .. KNOWN_FILES.positions) then
    local accountName = "Schwab Brokerage"
    local accountNumber = ""
    local content = readFile(dir .. KNOWN_FILES.positions)
    if content then
      local acct = content:match("account%s+%S+%s+(%S+)")
      if acct then
        accountNumber = acct
        accountName = "Schwab " .. acct
      end
    end
    accounts[#accounts + 1] = {
      name          = accountName,
      accountNumber = accountNumber,
      subAccount    = "brokerage",
      currency      = "USD",
      portfolio     = true,
      type          = AccountTypePortfolio,
    }
  end

  if #accounts == 0 and fileExists(dir .. KNOWN_FILES.transactions) then
    accounts[#accounts + 1] = {
      name          = "Schwab Portfolio",
      accountNumber = "",
      subAccount    = "txn",
      currency      = "USD",
      portfolio     = true,
      type          = AccountTypePortfolio,
    }
  end

  return accounts
end

function RefreshAccount(account, _since)
  local securities = {}
  local transactions = {}
  local balance = 0
  local dir = getDataDir()
  if not dir then return { balance = 0, securities = {}, transactions = {} } end

  if account.subAccount == "eac" then
    local content = readFile(dir .. KNOWN_FILES.eac)
    if content then
      securities, balance = parseEac(content)
    end
  elseif account.subAccount == "brokerage" then
    local content = readFile(dir .. KNOWN_FILES.positions)
    if content then
      local secs, _, totalValue = parsePositions(content) -- luacheck: ignore 211
      securities = secs
      -- totalValue (from "Account Total" row) already includes cash
      balance = totalValue
    end
  end

  local txnContent = readFile(dir .. KNOWN_FILES.transactions)
  if txnContent then
    transactions = parseTransactions(txnContent)
  end

  return {
    balance      = balance,
    securities   = securities,
    transactions = transactions,
  }
end

function EndSession()
end

-- ---------------------------------------------------------------------------
-- Self-tests (run with: lua extension/SchwabPortfolio.lua)
-- These only execute when the file is run directly, not when loaded by MoneyMoney.
-- ---------------------------------------------------------------------------
-- luacheck: push
-- luacheck: ignore 631

if arg then
  local passed = 0
  local failed = 0

  local function assert_eq(name, got, expected)
    if got == expected then
      passed = passed + 1
    else
      failed = failed + 1
      io.stderr:write("FAIL: " .. name .. "\n")
      io.stderr:write("  expected: " .. tostring(expected) .. "\n")
      io.stderr:write("  got:      " .. tostring(got) .. "\n")
    end
  end

  local function assert_near(name, got, expected, tol)
    tol = tol or 0.01
    if got and math.abs(got - expected) < tol then
      passed = passed + 1
    else
      failed = failed + 1
      io.stderr:write("FAIL: " .. name .. "\n")
      io.stderr:write("  expected: ~" .. tostring(expected) .. "\n")
      io.stderr:write("  got:      " .. tostring(got) .. "\n")
    end
  end

  -- parseCsvLine
  local fields = parseCsvLine('"hello","world",123')
  assert_eq("csv basic: field count", #fields, 3)
  assert_eq("csv basic: quoted field", fields[1], "hello")
  assert_eq("csv basic: unquoted field", fields[3], "123")

  fields = parseCsvLine('"has ""quotes""",empty,,"last"')
  assert_eq("csv quotes: escaped quotes", fields[1], 'has "quotes"')
  assert_eq("csv quotes: empty field", fields[3], "")
  assert_eq("csv quotes: last field", fields[4], "last")

  fields = parseCsvLine('"06-08-2022",NVDA,RSU,"$0.00","2,240","$24,329.20"')
  assert_eq("csv rsu: date", fields[1], "06-08-2022")
  assert_eq("csv rsu: symbol", fields[2], "NVDA")
  assert_eq("csv rsu: quantity with commas", fields[5], "2,240")

  -- parseMoney
  assert_near("money: basic", parseMoney("$48.08"), 48.08)
  assert_near("money: thousands", parseMoney("$24,329.20"), 24329.20)
  assert_near("money: negative", parseMoney("-$100.50"), -100.50)
  assert_eq("money: empty", parseMoney(""), nil)
  assert_eq("money: dashes", parseMoney("--"), nil)
  assert_near("money: zero", parseMoney("$0.00"), 0.00)

  -- parseQuantity
  assert_near("qty: basic", parseQuantity("980"), 980)
  assert_near("qty: thousands", parseQuantity("2,240"), 2240)
  assert_near("qty: quoted", parseQuantity('"140"'), 140)
  assert_eq("qty: empty", parseQuantity(""), nil)
  assert_eq("qty: dashes", parseQuantity("--"), nil)

  -- parseDateMDY
  local ts = parseDateMDY("03-15-2023")
  local d = os.date("*t", ts)
  assert_eq("date MDY: year", d.year, 2023)
  assert_eq("date MDY: month", d.month, 3)
  assert_eq("date MDY: day", d.day, 15)

  ts = parseDateMDY("12/25/2024")
  d = os.date("*t", ts)
  assert_eq("date slash: month", d.month, 12)
  assert_eq("date slash: day", d.day, 25)

  assert_eq("date: empty", parseDateMDY(""), nil)
  assert_eq("date: nil", parseDateMDY(nil), nil)

  -- formatDateISO
  assert_eq("iso: dash format", formatDateISO("03-15-2023"), "2023-03-15")
  assert_eq("iso: slash format", formatDateISO("12/01/2024"), "2024-12-01")
  assert_eq("iso: quoted", formatDateISO('"06-08-2022"'), "2022-06-08")

  -- isDataRow / isHeaderRow (return truthy/falsy, not strict true/false)
  assert_eq("datarow: date", isDataRow({"06-08-2022", "NVDA"}) ~= nil, true)
  assert_eq("datarow: header", isDataRow({"Award Date", "Symbol"}) ~= nil, false)
  assert_eq("headerrow: award", isHeaderRow({"Award Date", "Symbol"}) ~= nil, true)
  assert_eq("headerrow: purchase", isHeaderRow({"Purchase Date", "Symbol"}) ~= nil, true)
  assert_eq("headerrow: data", isHeaderRow({"06-08-2022", "NVDA"}) ~= nil, false)

  -- checkSecurity
  local goodSec = { name = "TEST", quantity = 100, price = 50.0, amount = 5000.0 }
  assert_eq("check: valid security", checkSecurity(goodSec, 1), true)
  assert_eq("check: zero quantity", checkSecurity({ name = "X", quantity = 0, price = 1 }, 1), false)
  assert_eq("check: negative price", checkSecurity({ name = "X", quantity = 1, price = -1 }, 1), false)

  -- parseEac: full integration test with sample data
  local sampleEac = [[
Equity Details for Equity Awards Center account as of 11:35 AM ET - 03/26/2026


*** RESTRICTED STOCK UNITS ***

Award Date,Symbol,Award Type,Award Price,Granted,Unvested Market Value,Tax Election,Award ID,Vested,Unvested,Canceled,Grant Agreement Status
"06-08-2022",ACME,RSU,"$0.00","1,000","$10,000.00",Withhold Shares,100001,"800","200","0",Accepted
Totals,,,,,"$10,000.00",,,


Vesting Schedules
 ,Award ID ,Vest Date ,# of Shares
 ,100001,"06-17-2026","200"
Past Vestings
 ,100001,"03-15-2023","400"
 ,100001,"09-20-2023","400"


*** EMPLOYEE STOCK PURCHASE PLAN SHARES ***

Purchase Date,Symbol,Plan Id,Market Value,Deposit Date,Purchase Price,Date Holding Period Met,Shares Purchased,Available to Sell,Subscription Date,Subscription FMV,Purchase FMV
02-28-2023,ACME,3,15000,02-28-2023,10,Qualified,500,500,09-01-2022,12,20
08-31-2023,ACME,3,9000,08-31-2023,10,Qualified,300,300,09-01-2022,12,30
02-28-2025,ACME,3,4000,02-28-2025,80,09-04-2026,100,100,09-03-2024,90,100
Totals,,,,,,,,900


*** EQUITY AWARD SHARES ***

Award Date,Symbol,Award ID,Share Type,Market Value,Date Holding Period Met,Deposit Date,Date Acquired,Acquisition Price,Shares,Available to Sell
06-08-2022,ACME,100001,Restricted Stock,0,N/A,03-15-2023,03-15-2023,25,400,0
06-08-2022,ACME,100001,Restricted Stock,6000,N/A,09-20-2023,09-20-2023,40,400,200
Totals,,,,,,,,,,200


Please exercise with caution when downloading data.
]]

  local securities, totalValue = parseEac(sampleEac)

  -- ESPP lots
  local esppLots = {}
  local rsuLots = {}
  for _, sec in ipairs(securities) do
    if sec.name:match("ESPP") then
      esppLots[#esppLots + 1] = sec
    elseif sec.name:match("RSU") then
      rsuLots[#rsuLots + 1] = sec
    end
  end

  assert_eq("eac: total securities", #securities, 4)
  assert_eq("eac: ESPP lot count", #esppLots, 3)
  assert_eq("eac: RSU lot count", #rsuLots, 1)

  -- Helper: find a security by name pattern
  local function findSec(list, pattern)
    for _, sec in ipairs(list) do
      if sec.name:match(pattern) then return sec end
    end
    return nil
  end

  -- ESPP lot: 500 shares @ $10, market value $15,000
  local espp_feb23 = findSec(esppLots, "2023%-02%-28 Q")
  assert_eq("espp feb23: found", espp_feb23 ~= nil, true)
  assert_eq("espp feb23: name has sub date",
    espp_feb23.name:match("Sub 2022%-09%-01") ~= nil, true)
  assert_eq("espp feb23: quantity", espp_feb23.quantity, 500)
  assert_near("espp feb23: purchase price", espp_feb23.purchasePrice, 10.00)
  assert_near("espp feb23: amount", espp_feb23.amount, 15000.00)
  assert_eq("espp feb23: currency", espp_feb23.currencyOfPrice, "USD")

  -- ESPP lot: disqualifying disposition
  local espp_dq = findSec(esppLots, "2025%-02%-28 DQ")
  assert_eq("espp dq: found", espp_dq ~= nil, true)
  assert_eq("espp dq: name has qual date",
    espp_dq.name:match("Qual 2026%-09%-04") ~= nil, true)
  assert_eq("espp dq: quantity", espp_dq.quantity, 100)
  assert_near("espp dq: purchase price", espp_dq.purchasePrice, 80.00)

  -- RSU lot: 200 available shares @ $40 acquisition, market value $6,000
  local rsu1 = findSec(rsuLots, "2023%-09%-20")
  assert_eq("rsu1: found", rsu1 ~= nil, true)
  assert_eq("rsu1: name has grant date",
    rsu1.name:match("Grant 2022%-06%-08") ~= nil, true)
  assert_eq("rsu1: quantity", rsu1.quantity, 200)
  assert_near("rsu1: acquisition price", rsu1.purchasePrice, 40.00)
  assert_near("rsu1: amount", rsu1.amount, 6000.00)
  assert_near("rsu1: current price", rsu1.price, 30.00) -- 6000/200

  -- Verify sort order: newest first
  for j = 1, #securities - 1 do
    assert_eq("sort: " .. j .. " >= " .. (j + 1),
      (securities[j].tradeTimestamp or 0) >= (securities[j + 1].tradeTimestamp or 0), true)
  end

  -- Total value = ESPP (15000 + 9000 + 4000) + RSU (6000) = 34000
  assert_near("eac: total value", totalValue, 34000.00)

  -- Sold lots (Available=0) should not appear
  for _, sec in ipairs(securities) do
    if sec.name:match("2023%-03%-15") then
      failed = failed + 1
      io.stderr:write("FAIL: sold lot (Available=0) should not appear: " .. sec.name .. "\n")
    end
  end
  passed = passed + 1 -- count the "no sold lots" check

  -- parsePositions: integration test
  local samplePositions = [[
"Positions for account Individual XXXX-1234 as of 03:30 PM ET, 03/26/2026"
""
"Symbol","Description","Quantity","Price","Price Change %","Price Change $","Market Value","Day Change %","Day Change $","Cost Basis","Gain/Loss %","Gain/Loss $","Ratings","Reinvest Dividends?","Capital Gains?","% Of Account","Security Type"
"ACME","Acme Corp","100","$50.00","0.5%","$0.25","$5,000.00","0.5%","$25.00","$4,000.00","25%","$1,000.00","--","No","--","80%","Stocks"
"Cash & Cash Investments","--","--","--","--","--","$1,000.00","--","--","--","--","--","--","--","--","20%","Cash and Money Market"
"Account Total","--","--","--","--","--","$6,000.00","--","--","--","--","--","--","--","--","--","--"
]]

  local posSecs, cashBal, posTotal = parsePositions(samplePositions)
  assert_eq("pos: security count", #posSecs, 1)
  assert_eq("pos: symbol", posSecs[1].securityNumber, "ACME")
  assert_eq("pos: quantity", posSecs[1].quantity, 100)
  assert_near("pos: price", posSecs[1].price, 50.00)
  assert_near("pos: purchase price", posSecs[1].purchasePrice, 40.00) -- 4000/100
  assert_near("pos: market value", posSecs[1].amount, 5000.00)
  assert_near("pos: cash balance", cashBal, 1000.00)
  assert_near("pos: total", posTotal, 6000.00)

  -- parseTransactions: integration test
  local sampleTxn = [[
"Transactions  for account XXXX-1234 as of 03/26/2026 10:00:00 AM ET"
"Date","Action","Symbol","Description","Quantity","Price","Fees & Comm","Amount"
"03/15/2023","Stock Plan Activity","ACME","ACME CORP","400","$25.00","","-$10000.00"
"03/20/2023","Cash Dividend","ACME","ACME CORP","","","","$50.00"
"Transactions Total","","","","","","","$-9950.00"
]]

  local txns = parseTransactions(sampleTxn)
  assert_eq("txn: count", #txns, 2)
  assert_eq("txn1: booking text", txns[1].bookingText, "Stock Plan Activity")
  assert_near("txn1: amount", txns[1].amount, -10000.00)
  assert_eq("txn1: purpose has shares", txns[1].purpose:match("400 shares") ~= nil, true)
  assert_eq("txn2: booking text", txns[2].bookingText, "Cash Dividend")
  assert_near("txn2: amount", txns[2].amount, 50.00)

  -- Summary
  print(string.format("\n%d passed, %d failed", passed, failed))
  if failed > 0 then
    os.exit(1)
  end
end
-- luacheck: pop
