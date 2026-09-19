#!/bin/bash
# One-time enrollment only. This script does NOT fabricate a GUI login with su/asuser.
set -euo pipefail
[[ $(uname -s) == Darwin && $EUID == 0 ]] || { echo 'Run on macOS with sudo bash scripts/prepare.sh NAME.' >&2; exit 1; }
name=${1:-demo}
[[ $name =~ ^[a-z][a-z0-9_]{0,19}$ && $name != *$'\n'* ]] || { echo 'Invalid box name.' >&2; exit 1; }
host=${SUDO_USER:-}
[[ -n $host && $host != root ]] || { echo 'Use sudo from the physical desktop user.' >&2; exit 1; }
host_uid=$(id -u "$host")
[[ $host_uid -ge 501 && $(stat -f %u /dev/console) == "$host_uid" ]] || { echo 'The caller must own the active host desktop.' >&2; exit 1; }
account="ub_$name"; group="ubx_$name"
config_dir='/Library/Application Support/UserBox/boxes'
config="$config_dir/$name.json"
here=$(cd "$(dirname "$0")" && pwd)
built="$here/../dist"
[[ ! -d "$here/UserBox.app" ]] || built="$here"
[[ -x "$built/UserBox.app/Contents/MacOS/UserBox" && -x "$built/UserBoxSession.app/Contents/MacOS/UserBoxSession" ]] || {
    echo 'Build first with bash scripts/build.sh, or run the extracted CI distribution.' >&2; exit 1;
}
# Refuse pre-existing accounts/groups unless this exact root-owned enrollment already exists.
if [[ -e $config ]]; then
    [[ ! -L $config && $(stat -f %u "$config") == 0 && $(stat -f %Lp "$config") == 644 ]] || { echo 'Unsafe existing configuration.' >&2; exit 1; }
    [[ $(plutil -extract hostUID raw -o - "$config") == "$host_uid" && $(plutil -extract username raw -o - "$config") == "$account" ]] || { echo 'Existing enrollment belongs to another host.' >&2; exit 1; }
    [[ $(id -u "$account") == $(plutil -extract guestUID raw -o - "$config") ]] || { echo 'Account identity changed; refusing re-enrollment.' >&2; exit 1; }
else
    if id "$account" >/dev/null 2>&1 || dscl . -read "/Groups/$group" >/dev/null 2>&1; then
        echo 'An unmanaged account or group already uses this name. Choose another Box name.' >&2; exit 1
    fi
    printf 'Creating standard account %s. Choose its password at the system prompt; it is not placed in arguments or logs.\n' "$account"
    sysadminctl -addUser "$account" -fullName "UserBox $name" -home "/Users/$account" -password -
    id "$account" >/dev/null || { echo 'Account creation did not complete.' >&2; exit 1; }
    dseditgroup -o create "$group"
fi
guest_uid=$(id -u "$account")
[[ $guest_uid -ge 501 && $guest_uid != "$host_uid" ]] || { echo 'Invalid guest identity.' >&2; exit 1; }
dseditgroup -o edit -a "$host" -t user "$group"
dseditgroup -o edit -a "$account" -t user "$group"
for path in '/Library/Application Support/UserBox' "$config_dir" /Users/Shared/UserBox "/Users/Shared/UserBox/$name" "/Users/Shared/UserBox/$name/run"; do
    [[ ! -L $path ]] || { echo "Refusing symlink at $path" >&2; exit 1; }
done
install -d -o root -g wheel -m 0755 '/Library/Application Support/UserBox' "$config_dir" /Users/Shared/UserBox
install -d -o root -g "$group" -m 0750 "/Users/Shared/UserBox/$name"
install -d -o "$account" -g "$group" -m 2750 "/Users/Shared/UserBox/$name/run"
# Explicit host ACL avoids depending on a refreshed supplementary-group list in an already running host process.
chmod +a "user:$host allow list,search,readattr,readextattr,readsecurity" "/Users/Shared/UserBox/$name" 2>/dev/null || true
chmod +a "user:$host allow read,write,execute,readattr,readextattr,readsecurity,file_inherit,directory_inherit" "/Users/Shared/UserBox/$name/run" 2>/dev/null || true
for product in UserBox UserBoxSession; do
    target="/Applications/$product.app"
    [[ ! -L $target ]] || { echo 'Refusing symlink application target.' >&2; exit 1; }
    if [[ -e $target ]]; then
        expected=io.userbox.viewer; [[ $product != UserBoxSession ]] || expected=io.userbox.session
        [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist") == "$expected" ]] || { echo 'Refusing to replace an unrelated app.' >&2; exit 1; }
    fi
    ditto "$built/$product.app" "$target"
    chown -R root:wheel "$target"
    chmod -R go-w "$target"
    codesign --verify --strict "$target"
done
install -d -o root -g wheel -m 0755 /usr/local/bin
install -o root -g wheel -m 0755 "$built/userboxctl" /usr/local/bin/userboxctl
# Write metadata with a root-owned temporary file in the trusted configuration directory.
tmp=$(mktemp "$config_dir/.enroll.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '{"version":1,"name":"%s","username":"%s","hostUID":%s,"guestUID":%s}\n' "$name" "$account" "$host_uid" "$guest_uid" > "$tmp"
chmod 0644 "$tmp"; chown root:wheel "$tmp"; plutil -lint "$tmp"; mv "$tmp" "$config"
agent_dir="/Users/$account/Library/LaunchAgents"
log_dir="/Users/$account/Library/Logs/UserBox"
sudo -u "$account" /bin/mkdir -p "$agent_dir" "$log_dir"
sudo -u "$account" /bin/chmod 0700 "$log_dir"
plist="$agent_dir/io.userbox.session.plist"
[[ ! -L $plist ]] || { echo 'Refusing symlink LaunchAgent.' >&2; exit 1; }
sudo -u "$account" /usr/bin/tee "$plist" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.userbox.session</string>
<key>ProgramArguments</key><array><string>/Applications/UserBoxSession.app/Contents/MacOS/UserBoxSession</string><string>--box</string><string>$name</string></array>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardErrorPath</key><string>$log_dir/session-error.log</string>
</dict></plist>
PLIST
sudo -u "$account" /bin/chmod 0644 "$plist"; plutil -lint "$plist"
if launchctl print "gui/$guest_uid" >/dev/null 2>&1; then
    launchctl bootout "gui/$guest_uid/io.userbox.session" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$guest_uid" "$plist"
fi
printf '\nEnrolled %s (UID %s), controlled only by %s (UID %s).\n' "$account" "$guest_uid" "$host" "$host_uid"
printf 'Open UserBox. Enable macOS Screen Sharing for this dedicated user in System Settings, then choose Start desktop.\n'
printf 'Authenticate as %s; choose its own login, never Share Display. Approve capture/input permissions inside that account.\n' "$account"
printf 'No Screen Sharing, firewall, FileVault, SIP, or TCC settings were changed by this script.\n'
