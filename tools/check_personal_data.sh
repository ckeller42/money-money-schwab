#!/bin/bash
# Scan text files for data that looks like real Schwab / personal data.
# Single implementation shared by CI (.github/workflows/ci.yml) and the
# local pre-commit hook (.githooks/pre-commit).
#
# Usage:
#   tools/check_personal_data.sh FILE...          scan the named files
#   git ls-files | tools/check_personal_data.sh   scan the files listed on stdin
#   tools/check_personal_data.sh --staged         scan the STAGED blobs (hook)
#
# Exit status: 0 clean, 1 a rule matched, 2 usage/setup error.
#
# This is a public repo and CI logs are public, so a hit prints only
# "file:line: rule <name>", NEVER the matched line. Find the value locally
# with the printed file:line.
#
# Fixtures and docs must use the designated synthetic values only (see
# CLAUDE.md). Never list real values in an allowlist below: that leaks them.
set -u

staged=0
if [ "${1:-}" = "--staged" ]; then
  staged=1
  shift
fi

tmp=""
cleanup() { [ -z "$tmp" ] || rm -rf "$tmp"; }
trap cleanup EXIT

# Collect the file list (arguments, else stdin, else the staged set).
files=()
if [ "$staged" -eq 1 ]; then
  tmp=$(mktemp -d) || exit 2
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Scan the staged blob (`git show :path`), not the working tree.
    mkdir -p "$tmp/$(dirname "$f")" || exit 2
    git show ":$f" >"$tmp/$f" 2>/dev/null || continue
    files+=("$f")
  done < <(git diff --cached --name-only --diff-filter=ACMR)
  cd "$tmp" || exit 2
elif [ "$#" -gt 0 ]; then
  files=("$@")
else
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "check_personal_data: no files to scan."
  exit 0
fi

found=0

# scan RULE_NAME PATTERN ALLOWLIST_KIND ALLOWLIST
#   Reports every line matching PATTERN (ERE) that does not match the
#   allowlist (a line matching the allowlist is accepted, as in the original
#   inline scan). `-I` skips binary files. The allowlist is applied to the
#   line content only, never to the file name.
scan() {
  local rule=$1 pattern=$2 kind=$3 allow=$4 line rest loc hit=0
  while IFS= read -r line; do
    rest=${line#*:}
    rest=${rest#*:}
    loc=${line%":$rest"}
    if [ "$kind" = "E" ]; then
      if printf '%s\n' "$rest" | grep -qE "$allow"; then continue; fi
    else
      if printf '%s\n' "$rest" | grep -q "$allow"; then continue; fi
    fi
    echo "$loc: rule $rule matched (value withheld)"
    hit=1
  done < <(grep -HInE "$pattern" -- "${files[@]}" 2>/dev/null)
  if [ "$hit" -eq 1 ]; then
    found=1
  fi
}

# Any bare 6-digit number could be a real Schwab award ID. Only the
# designated synthetic IDs (100001, 123456) are allowed. Never list real
# IDs here: a blocklist of real values would itself leak them.
scan award-id '\b[0-9]{6}\b' E '\b(100001|123456|000000)\b'

# 3-decimal prices are the signature of real Schwab export data.
# Only the designated synthetic prices (12.345, 23.456) are allowed.
scan price-3-decimals '\b[0-9]{1,4}\.[0-9]{3}\b' E '\b(12\.345|23\.456)\b'

# Email addresses (except known safe ones).
scan email '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' B \
  'noreply@anthropic\|users\.noreply\.github\.com\|bundesbank\.de\|example\.com'

# Home directory paths with real usernames.
scan home-path '/Users/[a-z]+[a-z0-9]*/' B \
  '__HOME__\|/Users/yourname\|/Users/you\b'

if [ "$found" -eq 1 ]; then
  echo "Personal data check FAILED: see file:line above (matched values are withheld)."
  exit 1
fi
echo "No secrets or personal data found."
