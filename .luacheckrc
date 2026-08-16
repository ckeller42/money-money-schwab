-- luacheck configuration for MoneyMoney extensions

std = "lua54"
max_line_length = 120

-- Variables prefixed with _ are intentionally unused (MoneyMoney API contract)
unused_args = false

-- MoneyMoney Web Banking API globals (defined by the runtime)
-- Using globals (not read_globals) so the test stubs can set them
globals = {
  "WebBanking",
  "LocalStorage",
  "Connection",
  "HTML",
  "MM",

  -- Account type constants
  "AccountTypePortfolio",
  "AccountTypeGiro",
  "AccountTypeSavings",
  "AccountTypeCreditCard",
  "AccountTypeCash",
  "AccountTypeOther",

  -- Protocol constants
  "ProtocolWebBanking",

  -- Functions we define that MoneyMoney calls
  "SupportsBank",
  "InitializeSession",
  "InitializeSession2",
  "ListAccounts",
  "RefreshAccount",
  "EndSession",
}
