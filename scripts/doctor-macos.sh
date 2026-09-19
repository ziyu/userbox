#!/bin/bash
# Read-only diagnostics. No account creation, service activation or TCC changes.
set -u
[[ $(uname -s) == Darwin ]] || { echo 'macOS required.' >&2; exit 1; }
BOX="${1:-ub_demo}"
[[ "$BOX" =~ ^ub_[a-z0-9_]{1,24}$ ]] || exit 1
FAIL=0
check() { local title="$1"; shift; if "$@"; then printf '[PASS] %s\n' "$title"; else printf '[FAIL] %s\n' "$title"; FAIL=1; fi; }
sw_vers
check 'Command Line Tools' xcrun --find swift
check 'Box account' id "$BOX"
if id "$BOX" >/dev/null 2>&1; then
  UID_BOX="$(id -u "$BOX")"
  check 'Different from host account' test "$UID_BOX" -ne "$(id -u)"
  check 'Root-owned configuration exists' test -r "/Library/Application Support/UserBox/$BOX/config.json"
  # The Box home is private; lack of host access is not a missing helper.
  printf '[INFO] The Aqua LaunchAgent is in the Box private home; inspect it as that user or root.\n'
  check 'Witness socket (requires an actual GUI login)' test -S "/Users/Shared/.userbox-$UID_BOX/witness.sock"
fi
check 'Built-in Screen Sharing accepts local TCP' nc -z -w 2 127.0.0.1 5900
check 'Installed application signature' codesign --verify --strict /Applications/UserBox.app
printf '\nA listening port or a user UID does NOT prove a separate desktop.\n'
printf 'UserBox additionally requires an off-console Aqua witness and fresh two-corner pixel challenges.\n'
exit "$FAIL"
