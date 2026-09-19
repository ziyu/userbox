# macOS demo setup

## 1. Install the native programs

macOS 13+ is the source deployment target. Native compilation requires a Swift 5.9+ toolchain. The hosted workflow builds development bundles; it does not log a second human into a Mac.

From the checkout run `bash scripts/build.sh`, then `sudo bash scripts/prepare.sh demo`. The script requires the calling desktop user to be the physical console owner. It creates standard account `ub_demo`, an account-specific socket access group, metadata under `/Library/Application Support/UserBox/boxes`, and an Aqua-only LaunchAgent. It installs `UserBox.app`, `UserBoxSession.app`, and `/usr/local/bin/userboxctl`.

Choose the dedicated account password at macOS's interactive `sysadminctl` prompt. Passwords are not sent in process arguments, written to configuration, or accepted by the UserBox protocol. Re-enrolling an existing managed Box preserves its account and password. Unmanaged name collisions are refused.

Packaged builds contain `Start UserBox.command`, which performs enrollment then opens the app without requiring a local build. A macOS security prompt may require explicit approval of this unnotarized developer build; do not disable Gatekeeper or SIP.

## 2. Establish the actual second desktop

In System Settings > General > Sharing, enable Screen Sharing and restrict access to the dedicated Box user. Do not enable the legacy shared VNC password. Consider the network exposure of Apple's system sharing service; UserBox's own relay listens only on 127.0.0.1, but that does not automatically restrict Apple's port 5900 listener.

Open UserBox, leave the Box name as `demo`, and click **Start desktop**. This starts a bounded, loopback-only TCP relay to Apple's Screen Sharing service and opens an account-qualified `vnc:` URL in Apple's client. Use `ub_demo` in Apple's authentication UI, and choose its **own desktop/login**, not a request to share the current display. Keep this bootstrap connection open during the experiment.

This is a concrete login attempt, not a simulated desktop or a claim that macOS has a public “create Aqua session” API. The localhost relay, login selection, virtual display lifetime, and session-specific capture must pass the real-machine acceptance gate on the target macOS release. If Apple's client refuses loopback or only offers the host display, stop this attempt and record the failure. Do not switch the physical console or type into it to make the test pass.

The prepared LaunchAgent starts in the Box's new Aqua login. Click **Connect** if needed. The host verifies the Unix peer UID, helper UID, graphical-session UID, security-session ID, graphical/login flags, and that the physical console still belongs to the configured host user. A status-only helper or a root-launched process is not treated as a working desktop.

## 3. Grant normal per-account consent

Click **Permissions** after the helper connects. Consent prompts are issued from inside the verified Box session; use Apple's bootstrap view to grant **UserBoxSession** Screen Recording and Accessibility in that account's System Settings. If required by macOS, click **Restart helper** after approval. This restarts the helper, not Finder, other apps, or the desktop.

No TCC database modification, inherited host Accessibility permission, password capture, or private entitlements are used. The host viewer never calls `CGEvent.post`.

## 4. Operate real native applications

The UserBox picture comes from ScreenCaptureKit inside the dedicated account. It is a native NSView, not a WebView. By default it observes only. **Take over** acquires human control; click inside the picture to use keyboard/IME input. Only that view's events are forwarded. **Observe** releases the lease so an agent can acquire it. Reserved host system shortcuts can be sent using the explicit guest-shortcutcut buttons.

**Open Finder** opens the real Finder in the Box. The app picker discovers bundles under `/Applications`, `/System/Applications`, `/System/Library/CoreServices`, and the Box's own Applications directory. Launch results check the process's actual Unix UID. Applications use the Box's own preferences, browser profiles, and login keychain.

File import/export is explicit and capped at 16 MiB for this demo. Imports live in `~/Documents/UserBox/Imports` inside the Box. Existing files are not silently overwritten; transfer filenames cannot contain paths, control characters, or symlink traversals. Use the native file manager and dialogs normally within the account's OS permissions. Audio and clipboard bridging are not enabled.

## 5. Drive it from a local agent or script

Run as the configured host account, not root:

```sh
userboxctl --box demo status
userboxctl --box demo apps
userboxctl --box demo finder
userboxctl --box demo open /System/Applications/TextEdit.app
userboxctl --box demo screenshot /tmp/userbox.jpg
userboxctl --box demo click 0.5 0.5
userboxctl --box demo type 'Hello from the agent'
userboxctl --box demo smoke
```

Commands acquire an agent lease only when they mutate the Box. An active human lease blocks another agent. Protocol clients can use `UserBoxCore.BoxConnection` and retain a lease across multiple calls. The server renews a valid lease on authorized commands/status heartbeats, expires it after 15 seconds of inactivity, and releases pressed inputs on disconnect/takeover when the session is still safe.

## 6. Validate and remove

Run the native isolation test, then complete `acceptance.md`. A successful JSON status or successful compilation alone is not acceptance. Reports contain boolean host-interference observations and native file verification, never host text, account passwords, or screenshots.

To remove a Box's LaunchAgent and enrollment: `sudo bash scripts/uninstall.sh demo`. It deliberately retains the standard account, user files, native desktop and shared installed binaries. Log out normally and remove the account in Users & Groups after preserving any needed files. Unenrollment does not silently disable system Screen Sharing configured by the user.
