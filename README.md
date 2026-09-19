# UserBox — macOS prototype

A native desktop-in-a-window experiment: a dedicated local macOS account owns an Aqua session, real applications, Finder, windows and input. The host application displays that desktop and exposes a local computer-use CLI. No Linux substitute, browser desktop or guest OS is included.

**Status:** the Swift/AppKit application compiles and packages successfully on a macOS GitHub runner. Protocol and isolation tests pass. **A real secondary Aqua login, native app interaction and concurrent host-input isolation have not yet been demonstrated.** This is an executable engineering prototype, not a claim that the full desktop requirement has passed. See [validation](docs/VALIDATION.md).

## What is implemented

| Component | Implementation |
|---|---|
| Host application | Native AppKit window, embedded framebuffer, secure password field, connect/disconnect, Finder/application/file controls |
| Account setup | Explicit interactive creation of a standard `ub_*` account, protected config, private IPC and shared directory |
| Session helper | Aqua LaunchAgent running as the Box user; launches installed apps and Finder through that session's `NSWorkspace` |
| Desktop connection | Literal loopback Apple RFB connection, ARD username/password authentication, raw/CopyRect frame decoding |
| Input | Box-local pointer, buttons, drag, scroll, keys and Unicode text; manual/Agent ownership with handoff |
| Local integration | Peer-authenticated Unix sockets; CLI for screenshot, input, application launch and file opening |
| Wrong-desktop protection | Off-console UID checks, fresh two-corner pixel challenges, expiring proofs, no global-input fallback |
| Delivery | Swift package, native app packaging, ad-hoc signing, macOS CI, setup/diagnostics/acceptance/removal scripts |

These are implemented code paths, not a compatibility matrix of applications tested on a real Mac. Input composition, dialogs, drag-and-drop, minimization, reconnection and performance require the acceptance run below.

### The critical experiment

Apple documents a virtual desktop for a remote user different from the local logged-in user. That does **not** establish that this custom client can create that session simply by authenticating with ARD security type 30.

The demo initiates that login and waits for the Box's actual Aqua helper. It does not call `sudo -u` or `launchctl asuser` and pretend those created a graphical login. If macOS requires an additional Apple-specific login/session-selection exchange, this version will remain unverified and stop. Implementing and verifying that exchange is unfinished until tested against a real Mac; replacing it with host-desktop input is not an acceptable workaround.

## Build and prepare

Target: macOS 14+, Swift 5.10+ / Xcode Command Line Tools. Build on the Mac architecture on which you will run it. CI artifacts use their runner architecture, not a universal binary.

```bash
git clone https://github.com/ziyu/userbox.git
cd userbox
swift test
bash scripts/build-app.sh
bash scripts/setup-macos.sh plan ub_demo
sudo bash scripts/setup-macos.sh create ub_demo
```

The last command asks for explicit confirmation and a **new Box-account password** through macOS's account-management tool. It does not take passwords on the command line. Review the setup plan before running it: a standard account, its launch helper, `/Applications/UserBox.app`, configuration and an explicitly shared folder are created. Existing accounts are not adopted or overwritten.

In **System Settings → General → Sharing → Screen Sharing**, authorize **only the Box account**. Do not enable the legacy password-only VNC option. UserBox does not silently enable this system service or modify firewall, FileVault, SIP, TCC, Remote Management or your host login. Apple's Screen Sharing service may listen on network interfaces, even though UserBox connects only to loopback: use an updated Mac, review network exposure and do not expose port 5900 to the internet.

```bash
open /Applications/UserBox.app
```

Enter `ub_demo` and its password, then **Connect**. The password is not persisted; the demo does not promise secure erasure of Swift string copies in memory. Never enter the host-account password in the Box password field.

The view stays blank and rejects input until it verifies both the off-console session identity and fresh pixels from that session. **Verified** is a live routing check, not an end-to-end task-success certificate. Failed checks disconnect rather than control the local console. Two small colored challenge markers remain visible in the Box desktop during verification.

**Take Control** grants input to the viewer and pauses Agent input. **Return to Agent** reverses ownership. Toolbar application controls require viewer ownership. The normal window close button exits the host application; it does not delete the account. Session persistence after disconnection must be measured on the target Mac.

## Computer-use CLI

With a verified connection and ownership returned to Agent:

```bash
CLI=/Applications/UserBox.app/Contents/MacOS/userbox
"$CLI" ctl status
"$CLI" ctl launch com.apple.finder
"$CLI" ctl launch com.apple.TextEdit
"$CLI" ctl open /Users/Shared/UserBox/ub_demo
"$CLI" ctl snapshot /tmp/userbox-frame.png
"$CLI" ctl click 240 180 1
"$CLI" ctl type 'Hello from UserBox'
"$CLI" ctl key 0xff0d down
"$CLI" ctl key 0xff0d up
```

Coordinates are framebuffer pixels, with origin at the top left. Button masks: left `1`, middle `2`, right `4`. Scroll: `ctl scroll X Y N`, with positive values scrolling up. Use screenshots to choose coordinates; example coordinates are not asserted to target any particular control. Check subsequent frames and file contents rather than treating delivery acknowledgements as completed tasks.

Installed apps can be identified by bundle ID or an absolute `.app` path under the supported application directories. `open` is restricted to the Box's home, explicit shared directory and application directories. Host credentials and application profiles are not copied. Registering per-user-only host apps and migrating profiles are not implemented.

## Validate and remove

```bash
bash scripts/doctor-macos.sh ub_demo
bash scripts/acceptance-macos.sh ub_demo
# Explicit account deletion; preserves its home and shared files:
sudo bash scripts/setup-macos.sh remove ub_demo
```

The smoke script starts Finder, opens an explicitly shared test file with a native app and saves private screenshots. It deliberately does not print an overall PASS. Complete [the real-desktop acceptance procedure](docs/ACCEPTANCE.md), including concurrent typing on the host and a native Save dialog. Screenshots may contain private data and are ignored by Git.

Removal retains the account's home, shared files, the app and system Screen Sharing settings. Inspect those retained items explicitly; never remove unrelated accounts or directories to recover a failed setup. Provisioning is not a transactional installer: a midway failure can leave an account or metadata requiring deliberate cleanup.

## Architecture and safety

```text
Host user: UserBox.app / local CLI
   |  Unix socket (peer UID authenticated)
   +-------------------> Box Aqua LaunchAgent: identity, marker, native app launch
   |
   |  127.0.0.1:5900, Apple user authentication
   +-------------------> macOS Screen Sharing: actual desktop pixels and input
```

No third-party Swift dependencies. Authentication uses the legacy Apple wire protocol (DH + MD5 + AES-ECB) only on loopback, with CommonCrypto vectors tested on macOS. The small BigNat implementation is not constant-time and is not a general cryptography library. The protocol is not represented as a modern encrypted transport or a hostile-local-process security boundary.

The demo never posts host-global HID events. It drops RFB clipboard/bell messages and does not add an automatic clipboard/audio bridge. **Separate users are not a complete sandbox for malicious native apps:** shared hardware, native audio/system services, deliberate file sharing and privileged actions require further isolation work. The witness/pixel protocol is a prototype guard, not a formal proof of race-free isolation.

Rendering uses bounded raw framebuffers, nominally five full refreshes per second, and at most one pending UI frame delivery. CPU/GPU/RAM and input-latency claims require measurements; full refresh and authentication are intentionally not optimized yet.

## References

- [Apple: control/observe a different user's virtual desktop](https://support.apple.com/guide/remote-desktop/choose-how-to-control-and-observe-apd4f46319e/mac)
- [Apple TN2083: daemons, agents and graphical session context](https://developer.apple.com/library/archive/technotes/tn2083/_index.html)
- [noVNC's Apple ARD wire implementation](https://github.com/novnc/noVNC/blob/8994317bf3a6e10af18c10f63d9de130e3beada8/core/rfb.js), consulted for protocol interoperability, not used as a runtime dependency.
