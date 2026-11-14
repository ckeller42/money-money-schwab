#!/bin/bash
set -e

# ── paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTENSION_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions"
DATA_DIR="$EXTENSION_DIR/SchwabData"
# Prefer /Applications (shows in Launchpad), fall back to ~/Applications
APP_DIR="/Applications"
if [ ! -w "$APP_DIR" ]; then
  APP_DIR="$HOME/Applications"
  mkdir -p "$APP_DIR"
fi

# ── preflight ──────────────────────────────────────────────────────────────
if [ ! -d "$EXTENSION_DIR" ]; then
  echo "✗ MoneyMoney not found. Install it first from https://moneymoney-app.com"
  exit 1
fi
echo "MoneyMoney found."

# ── install extension (patch home path) ────────────────────────────────────
sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/extension/SchwabPortfolio.lua" \
  > "$EXTENSION_DIR/SchwabPortfolio.lua"
echo "✓ Extension installed"

# ── create data directory ──────────────────────────────────────────────────
mkdir -p "$DATA_DIR"
echo "✓ Data directory created"

# ── shell alias ───────────────────────────────────────────────────────────
echo ""
echo "To add a shell alias, add this line to your ~/.zshrc (or ~/.bashrc):"
echo "  alias schwab-sync='$SCRIPT_DIR/sync.sh'"
echo ""

# ── stable code-signing identity ───────────────────────────────────────────
# SchwabSync.app writes the synced CSV into MoneyMoney's TCC-protected container
# (~/Library/Containers/com.moneymoney-app.retail/Data/...). That write needs a
# TCC grant, and macOS keys the grant to the app's *designated requirement*. An
# ad-hoc signature's requirement is its cdhash, which changes on every rebuild,
# so the grant is lost each reinstall. A stable self-signed identity gives a
# cdhash-independent requirement (identifier + certificate), so the grant
# survives reinstalls. The private key never leaves this Mac's login keychain.
SIGN_CN="SchwabSync Signing"
BUNDLE_ID="io.github.ckeller42.schwabsync"

ensure_signing_identity() {
  # find-identity -v hides untrusted self-signed identities, so detect by cert.
  if security find-certificate -c "$SIGN_CN" >/dev/null 2>&1; then
    return 0
  fi
  echo "Creating a self-signed code-signing identity '$SIGN_CN' in your login keychain…"
  local tmp; tmp=$(mktemp -d)
  # LibreSSL (the macOS openssl) needs the code-signing EKU in a config file.
  cat > "$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $SIGN_CN
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  if openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 \
        -config "$tmp/req.cnf" >/dev/null 2>&1 &&
     openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/id.p12" -passout pass:schwabsync -name "$SIGN_CN" >/dev/null 2>&1 &&
     security import "$tmp/id.p12" -P schwabsync -T /usr/bin/codesign >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo "  On the first signing, macOS asks to let codesign use the key — click \"Always Allow\" (once)."
    return 0
  fi
  rm -rf "$tmp"
  echo "  – Could not create the signing identity automatically."
  echo "    Create one once in Keychain Access → Certificate Assistant → Create a Certificate"
  echo "    (name: $SIGN_CN, type: Code Signing), then re-run ./install.sh."
  return 1
}

# ── build and install SchwabSync app ──────────────────────────────────────
APPLESCRIPT="$SCRIPT_DIR/shortcut/SchwabSync.applescript"
if [ -f "$APPLESCRIPT" ]; then
  mkdir -p "$APP_DIR"
  if osacompile -o "$APP_DIR/SchwabSync.app" "$APPLESCRIPT" 2>/dev/null; then
    APP="$APP_DIR/SchwabSync.app"
    ICNS="$SCRIPT_DIR/shortcut/SchwabSync.icns"
    if [ -f "$ICNS" ]; then
      cp "$ICNS" "$APP/Contents/Resources/applet.icns"
      rm -f "$APP/Contents/Resources/Assets.car"
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" \
        "$APP/Contents/Info.plist" 2>/dev/null || true
      touch "$APP"
    fi
    # Bundle the sync script and converter INSIDE the app, so the app runs its
    # own signed copies instead of user-writable scripts from the checkout — a
    # tampered external script would otherwise inherit the app's file-access
    # grant. The applet resolves Contents/Resources/sync.sh at runtime.
    cp "$SCRIPT_DIR/sync.sh" "$SCRIPT_DIR/xlsx2csv" "$APP/Contents/Resources/"
    chmod +x "$APP/Contents/Resources/sync.sh" "$APP/Contents/Resources/xlsx2csv"
    # Give the bundle a stable identity (readable name in the Full Disk Access
    # list, stable TCC requirement), then sign — signing must be LAST, after all
    # Info.plist and Resources edits, or it invalidates the signature.
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
    plutil -replace CFBundleName       -string "SchwabSync" "$APP/Contents/Info.plist"
    if ensure_signing_identity && \
       codesign --force -s "$SIGN_CN" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
      echo "✓ SchwabSync.app installed and signed ($BUNDLE_ID)"
    else
      # Unsigned still runs; the container write just needs a re-grant each install.
      codesign --force -s - "$APP" 2>/dev/null || true
      echo "✓ SchwabSync.app installed to $APP_DIR (unsigned — see note below)"
    fi
  else
    echo "– SchwabSync.app: could not compile (osacompile not available?)"
    echo "  You can run sync.sh manually instead."
  fi
fi

# ── initial sync ───────────────────────────────────────────────────────────
"$SCRIPT_DIR/sync.sh" || true

# ── done ───────────────────────────────────────────────────────────────────
echo ""
echo "Setup complete. Next steps:"
echo "  1. Restart MoneyMoney"
echo "  2. Hold Option (⌥) + click Help menu → enable unsigned extensions"
echo "  3. Add Account → search for 'schwab-csv' → click through (leave fields empty)"
echo "  4. Open SchwabSync from Launchpad (or Spotlight) to download + sync"
echo ""
echo "  On the first SchwabSync run, macOS may ask to let SchwabSync access"
echo "  \"data from other apps\" — allow it (that grant lets it write MoneyMoney's"
echo "  data). If no prompt appears, add SchwabSync under System Settings →"
echo "  Privacy & Security → Full Disk Access. The signed identity keeps that"
echo "  grant across future ./install.sh runs."
