# UserBox

Native macOS desktop-in-a-window prototype. A dedicated local account owns the real Aqua session, applications, Finder and input; the host displays it without sending global HID events.

The first implementation is being added with a native Swift/AppKit viewer, local Apple RFB transport, an in-session identity witness, provisioning tools, CLI and tests.

**Validation status:** protocol/isolation tests have run on Linux. A real secondary macOS GUI login has not yet been validated. Compilation and real desktop acceptance are separate gates; this repository does not claim full macOS support until the latter passes.
