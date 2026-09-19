# macOS implementation notes

## Actual execution path

1. Enrollment creates a standard OS account and an Aqua-only LaunchAgent.
2. Apple's authenticated Screen Sharing path attempts to create/retain that user's separate graphical login through a localhost relay. This is the experimentally unverified platform integration, not a stubbed success result.
3. `UserBoxSession` runs in that login, captures its display with ScreenCaptureKit, and executes ordinary Launch Services application opens and session-level input.
4. The host connects through a Unix socket and verifies the peer UID. It renders JPEG frames in NSView; no browser engine, guest kernel, VM or application emulation is involved.

Apple's bootstrap client is used for login and initial permissions, not as the runtime framebuffer or control API. Its connection remains open in the demo, so it has real resource cost. The demo therefore does not claim minimal steady-state overhead or completely headless session creation.

## Trust boundary

Root is needed once to create the account and install root-owned application files/configuration. Neither runtime process runs as root. There is no arbitrary shell, sudo, AppleScript, host Accessibility event injection or privileged command RPC.

The private Unix socket authenticates both sides with `getpeereid`. The root-owned config fixes the host/guest UID pair. Each response is bound to a request ID. Envelopes are capped at 256 KiB and binary payloads at 16 MiB; reads/writes have deadlines. Session ID, graphical flag, login completion, account UID and physical-console owner are rechecked before every operation and after awaits. Input also checks immediately before posting to `cgSessionEventTap`. The host pins the first accepted session ID for a connection.

These are fail-closed policies, not a kernel-level mathematical guarantee against an OS session switch racing between a check and event delivery. Real concurrent input, session switching and capture isolation remain mandatory empirical gates. Unknown or changed sessions stop automation; there is no global-input fallback.

A dedicated account isolates normal per-user state, not CPU/GPU usage, the entire filesystem or networking. This is not a hostile-code sandbox. App installation files may be shared; writable profiles/keychains are not imported. File and app actions stay at the Box user's privilege level.

## Control and rendering

The server owns a per-desktop lease, keyed by connection ID plus an unpredictable token. Only an explicit human takeover can preempt a different live holder. The old token becomes invalid. Mouse/key state is released when safe. Bulk text yields between small batches so another controller can revoke it. The viewer coalesces move events and bounds its input queue.

ScreenCaptureKit is capped to a 1600-pixel width and 12 FPS, with three queued frames and audio disabled. Only the latest complete JPEG is cached; host decoding skips duplicate frame sequence numbers. Capture stops when the last client disconnects, while apps and the graphical login remain separate from viewing. Measure actual WindowServer, bootstrap-client, helper, app, CPU and GPU costs before setting a product resource budget.

## Sources

- Apple: separate authenticated user desktop versus shared physical display: https://support.apple.com/guide/remote-desktop/choose-how-to-control-and-observe-apd4f46319e/mac
- Apple TN2083: Aqua LaunchAgents, GUI bootstrap namespaces and why a UID alone is insufficient: https://developer.apple.com/library/archive/technotes/tn2083/_index.html
- Apple ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Apple session event location: https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cgsessioneventtap

The older architecture note supplies concepts, not a promise that an undocumented login mechanism remains stable. No undocumented framework is linked by this implementation.
