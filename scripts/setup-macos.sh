#!/bin/bash
# Explicit, interactive prototype provisioning. Never run from a model/tool in
# the background: creating a login account and changing sharing require consent.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'This script is macOS-only.' >&2; exit 1; }
ACTION="${1:-plan}"
BOX="${2:-ub_demo}"
[[ "$BOX" =~ ^ub_[a-z0-9_]{1,24}$ ]] || { echo 'Invalid Box name.' >&2; exit 1; }
ROOT="/Library/Application Support/UserBox/$BOX"
APP='/Applications/UserBox.app'
SOURCE="$(cd "$(dirname "$0")/.." && pwd)/dist/UserBox.app"
HOST="${SUDO_USER:-$(id -un)}"
HOST_UID="$(id -u "$HOST")"
[[ $HOST_UID -ge 501 && "$HOST" != "$BOX" ]] || { echo 'Run from the ordinary host account using sudo for create/remove.' >&2; exit 1; }

if [[ "$ACTION" == plan ]]; then
  cat <<PLAN
UserBox setup plan (no changes):
  1. Install the locally built, ad-hoc-signed app in $APP.
  2. Create standard login account $BOX; ask for its password through sysadminctl.
  3. Create a private host/Box IPC group and a root-owned configuration.
  4. Install a LaunchAgent in /Users/$BOX/Library/LaunchAgents.
  5. Create an explicitly shared directory /Users/Shared/UserBox/$BOX.
  6. Leave Screen Sharing, Remote Management, firewall, FileVault, SIP, TCC,
     the host account, host files and host login state unchanged.
After setup, macOS must authorize Screen Sharing for $BOX. Choose ONLY that user
in Sharing Settings. Do not enable legacy 'VNC viewers may control screen with password'.
Enabling Apple's Screen Sharing may listen on network interfaces as well as loopback;
review your macOS firewall/network policy. UserBox itself exposes only Unix sockets.
To apply: sudo bash scripts/setup-macos.sh create $BOX
PLAN
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo 'This action requires sudo.' >&2; exit 1; }

if [[ "$ACTION" == create ]]; then
  [[ -x "$SOURCE/Contents/MacOS/userbox" ]] || { echo 'First run bash scripts/build-app.sh.' >&2; exit 1; }
  [[ ! -e "$ROOT" && ! -L "$ROOT" ]] || { echo 'Box already configured. Refusing to overwrite state.' >&2; exit 1; }
  if id "$BOX" >/dev/null 2>&1; then echo 'Account already exists; refusing to adopt an unrelated account.' >&2; exit 1; fi
  [[ ! -e "/Users/$BOX" && ! -L "/Users/$BOX" ]] || { echo 'Home path already exists.' >&2; exit 1; }
  for path in '/Library/Application Support/UserBox' '/Users/Shared/UserBox' "$APP"; do
    [[ ! -L "$path" ]] || { echo "Refusing symlink: $path" >&2; exit 1; }
  done
  [[ -t 0 ]] || { echo 'An interactive terminal is required for password entry.' >&2; exit 1; }
  echo "This will create a standard macOS account $BOX and install its login helper."
  read -r -p 'Type CREATE to continue: ' CONFIRM
  [[ "$CONFIRM" == CREATE ]] || exit 1
  if [[ -e "$APP" ]]; then
    codesign --verify --strict "$APP"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == dev.userbox.mac-demo ]] || { echo 'An unrelated /Applications/UserBox.app exists.' >&2; exit 1; }
    # Do not replace a running executable, or silently install a different build.
    cmp "$SOURCE/Contents/MacOS/userbox" "$APP/Contents/MacOS/userbox" || { echo 'Installed build differs; stop UserBox and update it explicitly first.' >&2; exit 1; }
  else
    ditto "$SOURCE" "$APP"
    chown -R root:wheel "$APP"
    chmod -R go-w "$APP"
  fi
  echo 'Enter a NEW password for the Box account when macOS asks. It is not stored by this script.'
  /usr/sbin/sysadminctl -addUser "$BOX" -fullName "UserBox ($BOX)" -home "/Users/$BOX" -password -
  BOX_UID="$(id -u "$BOX")"
  [[ $BOX_UID -ge 501 && $BOX_UID -ne $HOST_UID ]] || { echo 'Unexpected account UID.' >&2; exit 1; }
  GROUP="userbox_$BOX_UID"
  if dscl . -read "/Groups/$GROUP" >/dev/null 2>&1; then echo 'IPC group unexpectedly exists; inspect provisioning state.' >&2; exit 1; fi
  dseditgroup -o create "$GROUP"
  dseditgroup -o edit -a "$HOST" -t user "$GROUP"
  dseditgroup -o edit -a "$BOX" -t user "$GROUP"
  GID="$(dscl . -read "/Groups/$GROUP" PrimaryGroupID | awk '{print $2}')"
  mkdir -p '/Library/Application Support/UserBox'
  chown root:wheel '/Library/Application Support/UserBox'; chmod 755 '/Library/Application Support/UserBox'
  install -d -o root -g "$GROUP" -m 750 "$ROOT"
  CONFIG="$ROOT/config.json"
  plutil -create xml1 "$CONFIG"
  plutil -insert username -string "$BOX" "$CONFIG"
  plutil -insert boxUID -integer "$BOX_UID" "$CONFIG"
  plutil -insert hostUID -integer "$HOST_UID" "$CONFIG"
  plutil -insert groupID -integer "$GID" "$CONFIG"
  plutil -insert root -string "$ROOT" "$CONFIG"
  plutil -convert json "$CONFIG"; chown root:"$GROUP" "$CONFIG"; chmod 640 "$CONFIG"
  # A distinct run directory per UID, too short to hit sockaddr_un's path limit.
  RUN="/Users/Shared/.userbox-$BOX_UID"
  [[ ! -e "$RUN" && ! -L "$RUN" ]] || { echo 'IPC directory unexpectedly exists.' >&2; exit 1; }
  install -d -o "$BOX" -g "$GROUP" -m 2710 "$RUN"
  install -d -o root -g wheel -m 755 '/Users/Shared/UserBox'
  install -d -o "$BOX" -g "$GROUP" -m 2770 "/Users/Shared/UserBox/$BOX"
  install -d -o "$BOX" -g staff -m 700 "/Users/$BOX/Library"
  install -d -o "$BOX" -g staff -m 700 "/Users/$BOX/Library/LaunchAgents"
  PLIST="/Users/$BOX/Library/LaunchAgents/dev.userbox.witness.plist"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.userbox.witness</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/userbox</string><string>--witness</string><string>$BOX</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
  chown "$BOX":staff "$PLIST"; chmod 600 "$PLIST"; plutil -lint "$PLIST"
  echo "Created $BOX (uid $BOX_UID). Host settings and Screen Sharing were not changed."
  echo "Now authorize ONLY $BOX in macOS Screen Sharing, then open $APP."
  echo 'The helper starts on a genuine GUI login; launchctl asuser does not create one.'
elif [[ "$ACTION" == remove ]]; then
  [[ -f "$ROOT/config.json" && ! -L "$ROOT/config.json" ]] || { echo 'No managed Box configuration found.' >&2; exit 1; }
  CONFIG="$ROOT/config.json"
  OWNER="$(plutil -extract hostUID raw "$CONFIG")"; BOX_UID="$(plutil -extract boxUID raw "$CONFIG")"
  [[ "$OWNER" == "$HOST_UID" && "$BOX_UID" == "$(id -u "$BOX")" ]] || { echo 'Account identity mismatch.' >&2; exit 1; }
  echo "Removal logs out and deletes ONLY the managed account $BOX. Its home and shared files will be retained."
  read -r -p "Type $BOX to confirm: " CONFIRM
  [[ "$CONFIRM" == "$BOX" ]] || exit 1
  launchctl bootout "gui/$BOX_UID/dev.userbox.witness" 2>/dev/null || true
  /usr/sbin/sysadminctl -deleteUser "$BOX" -keepHome
  if id "$BOX" >/dev/null 2>&1; then echo 'Account deletion did not complete; no cleanup performed.' >&2; exit 1; fi
  # Keep user data. Delete only exact metadata and the two known IPC entries.
  # The retained home is user-controlled. Do not follow its parents as root.
  rm -f -- "/Users/Shared/.userbox-$BOX_UID/witness.sock"
  rmdir -- "/Users/Shared/.userbox-$BOX_UID" 2>/dev/null || true
  rm -f -- "$ROOT/config.json"; rmdir -- "$ROOT"
  dseditgroup -o delete "userbox_$BOX_UID"
  echo 'Account removed. Retained its home, shared files, and UserBox.app; Screen Sharing settings are unchanged.'
else
  echo 'Usage: setup-macos.sh plan|create|remove [ub_demo]' >&2; exit 1
fi
