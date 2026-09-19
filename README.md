# UserBox

[中文说明](docs/README.zh-CN.md)

A **real native macOS desktop in a window**, owned by a dedicated OS account. Finder and applications run in that account's Aqua session. The host renders the real desktop, rather than recreating applications in HTML or running Linux substitutes.

This repository contains a working-code **macOS experiment**, not a claim of completed cross-platform support. The non-negotiable acceptance target is a native second desktop that does not take the physical user's mouse, keyboard, or focus.

## What is implemented

- Native SwiftUI/AppKit viewer with a letterboxed desktop surface, mouse movement, clicks/double-clicks, dragging, scrolling, raw keyboard shortcuts, and an `NSTextInputClient` Unicode/IME path.
- Per-account Aqua LaunchAgent: ScreenCaptureKit capture, session-local input, native app discovery/launch, Finder, explicit file import/export, and an actual TextEdit edit/save verification routine.
- Dedicated standard-account enrollment, root-owned metadata, Unix-domain sockets authenticated with OS peer credentials, session-ID pinning and per-operation off-console checks.
- Exclusive control leases: a human can preempt an agent; agents cannot steal a live human lease. No host HID fallback, clipboard sync, audio forwarding, or arbitrary privileged command endpoint.
- A CLI, 35 portable policy/transport tests, native macOS CI compilation and app packaging, and a real-machine acceptance checklist.

## Run the demo

See **[macOS setup and usage](docs/macos-demo.md)**. From source on a Mac:

```sh
swift test
bash scripts/build.sh
sudo bash scripts/prepare.sh demo
open /Applications/UserBox.app
```

Or obtain the `UserBox-macOS-demo` artifact from a **successful** GitHub Actions run, extract its inner ZIP, and launch `Start UserBox.command`. Artifacts are ad-hoc signed development builds, not notarized releases.

The demo uses **Apple Screen Sharing only to establish and retain the dedicated graphical login** through a local loopback relay. Account passwords remain in Apple's authentication UI. After login, the UserBox window receives pixels directly from its in-session helper and sends input directly to that helper. UserBox does not drive or scrape the host Screen Sharing window.

A real off-console login must be created and normal Screen Recording/Accessibility consent granted in the dedicated account. `sudo`, `su`, and `launchctl asuser` are not presented as substitutes for a graphical login. See the setup guide before starting.

## Validation: evidence, not labels

| Gate | Evidence |
|---|---|
| Portable code, framing, peer UID and policy tests | 35 tests passed on Linux/Swift 6.2.1 during development |
| Native macOS compilation and bundle signing | `.github/workflows/macos.yml`; check the run for the exact commit |
| Local loopback creation of a second Aqua desktop | Requires real-Mac acceptance; not established by Linux tests or hosted CI |
| Real native applications and no physical-input interference | `Run native isolation test` plus [acceptance checklist](docs/acceptance.md); not yet claimed as verified |

The code refuses an unverified or console session. That is a guard, **not proof that the session-creation mechanism succeeds on every Mac**. The full target remains unchanged; a failing real-desktop gate is unfinished engineering work, not a supported reduced mode.

## Layout

```text
Sources/UserBox/           Native viewer and human takeover
Sources/UserBoxMac/        Aqua helper, capture/input, local bootstrap relay
Sources/UserBoxCore/       Protocol, session policy, leases, RPC client
Sources/CUserBox/          Unix peer credentials and macOS session identity
Sources/UserBoxSession/    Per-user LaunchAgent executable
Sources/UserBoxCLI/        userboxctl
scripts/                  Build, enrollment and non-destructive unenrollment
```

[Design and safety](docs/design.md) · [Real-machine acceptance](docs/acceptance.md)
