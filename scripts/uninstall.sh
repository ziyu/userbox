#!/bin/bash
# Removes the selected enrollment only. Account and user files are intentionally retained.
set -euo pipefail
[[ $(uname -s) == Darwin && $EUID == 0 ]] || { echo 'Run with sudo on macOS.' >&2; exit 1; }
name=${1:-demo}
[[ $name =~ ^[a-z][a-z0-9_]{0,19}$ && $name != *$'\n'* ]] || exit 1
config="/Library/Application Support/UserBox/boxes/$name.json"
[[ -f $config && ! -L $config && $(stat -f %u "$config") == 0 ]] || { echo 'No safe enrollment found.' >&2; exit 1; }
account=$(plutil -extract username raw -o - "$config")
uid=$(plutil -extract guestUID raw -o - "$config")
[[ $account == "ub_$name" && $(id -u "$account") == "$uid" && $uid -ge 501 ]] || { echo 'Identity mismatch.' >&2; exit 1; }
launchctl bootout "gui/$uid/io.userbox.session" >/dev/null 2>&1 || true
sudo -u "$account" /bin/rm -f "/Users/$account/Library/LaunchAgents/io.userbox.session.plist"
rm -f "$config"
printf 'Removed enrollment %s. The standard account, native desktop, documents, and shared application installation were retained.\n' "$name"
printf 'Log out of that desktop normally and use Users & Groups to delete the account when its files are no longer needed.\n'
