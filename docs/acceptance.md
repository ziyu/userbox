# Real-Mac acceptance gate

Record macOS version/build, hardware, architecture, app commit and two UIDs. Do not replace a failed gate with a reduced product claim. Hosted CI cannot complete this checklist.

| Test | Required observable result |
|---|---|
| Enrollment | A standard dedicated user is created. No host password is logged. No SIP/TCC/FileVault changes. |
| Fresh native login | Start desktop creates the other user's actual Aqua session while the physical user remains logged in and keeps the same desktop. |
| Embedded picture | Real Finder/Dock/menus appear in UserBox. No simulated desktop, host-screen mirror or frame from another account. |
| App ownership | Open Finder, TextEdit and a host-installed third-party app. Returned PIDs really belong to the dedicated UID. |
| Input | Click/double-click, drag, scroll, text, Chinese IME, modifier shortcuts and native dialogs work within the Box. |
| No host interference | Run native isolation test with host typing-probe focused and pointer held still. Saved bytes match, and all three host-interference booleans remain false. |
| Concurrent human use | Repeat ordinary Box operations while using other host apps. Verify no cursor jump, dropped host text, focus steal, host popup or shared clipboard change. |
| Files | Explicit import, open/edit/save through native app/dialog, export; exported bytes match. No implicit host home/keychain sharing. |
| Preemption | Hold an agent lease, start bulk text, take over from the viewer. Old commands fail and no further agent text arrives. |
| Session switch | Change/lock/logout the host or guest. Uncertain sessions block commands; returning requires a valid identity. No HID fallback. |
| Lifetime | Minimize/occlude viewer, disconnect/reconnect, restart helper. Test bootstrap connection loss separately and record whether macOS retains the display. |
| Resource costs | Record idle and active RSS/CPU for both users' apps, WindowServer, bootstrap client, capture helper and viewer. Separate shared costs from per-Box costs. |
| Multi-Box | Enroll another name; create both native logins without switching the physical console; run independent operations and check all session identities. |

## Automated native routine

`Run native isolation test` in the viewer waits two seconds for the host probe to receive focus, records host foreground/focus/pointer baselines, and requests the helper's smoke routine. Inside the Box, the routine creates a uniquely named plain-text file, opens Finder and TextEdit, performs Command-A, types new content, performs Command-S, and reads the actual file until it exactly matches. Input dispatch success is not counted as save success. A real capture frame is also required.

The host samples for interference every 50 ms. Deliberately moving the host pointer or focus during the deterministic phase is a test failure, not evidence of a bug; run the separate concurrent-human-use test for that scenario. Reports never record host keystrokes or host screenshots. Failed native actions stay failures, even when portable unit tests passed.

## Current evidence

The 35 portable policy/transport tests passed under Linux with Swift 6.2.1. They exercise real Unix socket peer credentials and framing, plus pure session-guard and lease transitions. They do not call ScreenCaptureKit, synthesize macOS events, or create an Aqua login. Consult the exact GitHub Actions commit for native compilation. No real-Mac acceptance result has been fabricated or checked off in this repository.
