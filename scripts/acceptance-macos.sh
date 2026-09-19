#!/bin/bash
# Run after the app says Verified, with control returned to Agent.
# Creates only an explicitly named acceptance file in the Box's shared directory.
set -euo pipefail
BOX="${1:-ub_demo}"
[[ "$BOX" =~ ^ub_[a-z0-9_]{1,24}$ ]] || exit 1
CLI='/Applications/UserBox.app/Contents/MacOS/userbox'
SHARE="/Users/Shared/UserBox/$BOX"
REPORT="$PWD/acceptance-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$REPORT"
"$CLI" ctl status | tee "$REPORT/status.txt"
"$CLI" ctl launch com.apple.finder
"$CLI" ctl open "$SHARE"
sleep 1
"$CLI" ctl snapshot "$REPORT/finder.png"
FILE="$SHARE/userbox-acceptance-$(date +%s).txt"
printf 'UserBox native session acceptance\n' > "$FILE"
"$CLI" ctl open "$FILE"
sleep 1
"$CLI" ctl snapshot "$REPORT/native-app.png"
cat <<TEXT
Saved private local screenshots to $REPORT.
The commands above exercised real session-side app/file opening. They are NOT an
end-to-end PASS by themselves. Continue the manual input-isolation and save-dialog
checks in docs/ACCEPTANCE.md. Do not upload screenshots containing personal data.
TEXT
