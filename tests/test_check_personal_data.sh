#!/bin/bash
# Test for tools/check_personal_data.sh using synthetic fixtures only.
#
# "Bad" values are assembled at run time from fragments so that no tracked
# file contains a string the scanner would flag (the scanner scans this
# file too). Fragments are arbitrary, not real data.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$DIR/tools/check_personal_data.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

check() { # name, expected rc, actual rc
  if [ "$2" = "$3" ]; then echo "personal-data scan: $1 PASS"; else
    echo "personal-data scan: $1 FAIL (expected rc=$2, got rc=$3)"
    FAILS=$((FAILS + 1))
  fi
}

# Good: only designated synthetic values (ACME, 100001/123456, 12.345/23.456).
cat >"$WORK/good.txt" <<'GOOD'
ACME award 100001 sold at 12.345
ACME award 123456 sold at 23.456
contact: noreply@anthropic.com or someone@example.com
path /Users/yourname/Downloads and /Users/you/x and __HOME__/Library
GOOD
out=$(cd "$WORK" && "$SCAN" good.txt)
check "good fixture is clean" 0 $?

# Bad values, built from fragments.
printf 'ACME award %s%s\n' 987 654 >"$WORK/bad_id.txt"
printf 'ACME price %s.%s\n' 45 678 >"$WORK/bad_price.txt"
printf 'mail %s@%s.%s\n' someone acme test >"$WORK/bad_email.txt"
printf 'in /%s/%s/%s\n' Users jdoe Downloads >"$WORK/bad_path.txt"

for pair in bad_id:award-id bad_price:price-3-decimals bad_email:email bad_path:home-path; do
  f="${pair%%:*}.txt"
  rule="${pair##*:}"
  out=$(cd "$WORK" && "$SCAN" "$f" 2>&1)
  rc=$?
  check "$rule detected" 1 "$rc"
  case "$out" in
    *"$f:1: rule $rule matched"*) echo "personal-data scan: $rule reports file:line and rule PASS" ;;
    *) echo "personal-data scan: $rule output FAIL"; FAILS=$((FAILS + 1)) ;;
  esac
  # The matched value must never be echoed (public CI logs).
  if printf '%s' "$out" | grep -qE '987|654|45\.678|jdoe|someone'; then
    echo "personal-data scan: $rule LEAKED the value FAIL"
    FAILS=$((FAILS + 1))
  fi
done

# File list on stdin.
out=$(cd "$WORK" && printf 'good.txt\nbad_id.txt\n' | "$SCAN")
check "stdin file list" 1 $?

# An allowed value does not excuse a file name: the allowlist looks at content only.
mkdir "$WORK/sub"
printf 'ACME award %s%s\n' 987 654 >"$WORK/sub/100001.txt"
out=$(cd "$WORK" && "$SCAN" sub/100001.txt)
check "allowlisted file name does not hide a hit" 1 $?

# --staged scans the staged blob, not the working tree.
git init -q "$WORK/repo"
(
  cd "$WORK/repo" || exit 1
  git config user.email t@example.com
  git config user.name t
  cp "$WORK/bad_id.txt" f.txt
  git add f.txt
  cp "$WORK/good.txt" f.txt # working tree is clean, staged blob is not
  "$SCAN" --staged >/dev/null
)
check "--staged scans the staged blob" 1 $?
(
  cd "$WORK/repo" || exit 1
  cp "$WORK/good.txt" f.txt
  git add f.txt
  "$SCAN" --staged >/dev/null
)
check "--staged clean" 0 $?

if [ "$FAILS" -ne 0 ]; then
  echo "personal-data scan: $FAILS failure(s)"
  exit 1
fi
echo "personal-data scan: all PASS"
