#!/bin/bash
# Golden test for the xlsx2csv converter.
#
# The fixture deliberately stores ESPP data in sheet3.xml and Equity Award
# data in sheet2.xml (opposite of the converter's hardcoded fallbacks), so
# this test only passes if sheet-by-name resolution actually works.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
GOT="$("$DIR/xlsx2csv" "$DIR/tests/fixtures/sample_eac.xlsx")"
EXPECTED="$(cat "$DIR/tests/fixtures/expected_eac.csv")"
if [ "$GOT" = "$EXPECTED" ]; then
  echo "xlsx2csv: PASS"
else
  echo "xlsx2csv: FAIL"
  diff <(printf '%s' "$EXPECTED") <(printf '%s' "$GOT") || true
  exit 1
fi

# Negative test: garbage input must fail loudly, never emit a hollow CSV
# that would clobber a known-good schwab_eac.csv during sync.
if "$DIR/xlsx2csv" /dev/null >/dev/null 2>&1; then
  echo "xlsx2csv: FAIL (accepted /dev/null as input)"
  exit 1
else
  echo "xlsx2csv negative: PASS"
fi
