# Validation record

Date: 2026-09-19. Branch: `main`.

## Completed

- Linux x86_64, Swift 6.2.1: `swift test` — **20 tests, 0 failures** (14 core tests plus 6 full-protocol fixture tests).
- macOS GitHub runner (`macos-15`), native implementation and all 20 tests at `087d15970dcb2079b82b24e1ec6f4883fb0d10c3`: **native build job passed**. It ran Swift tests, release compilation, app-bundle creation, ad-hoc code signing/verification, actual CommonCrypto MD5/AES known-answer vectors and app artifact upload.
- Evidence: [native build run](https://github.com/ziyu/userbox/actions/runs/35442891034).
- All local shell scripts individually passed `bash -n`. No provisioning script was executed on a Mac as part of CI.

The subsequent changes in this delivery are documentation and ignore rules only. The compiled Swift source and tests are unchanged from the successful native-build commit above.

## Not completed

The live Mac workspace connector returned connection failures. No user's macOS account, desktop, Screen Sharing permission, firewall, TCC, SIP or FileVault was changed by this development session.

No real secondary Aqua login was established. Finder, native file editing/saving, user input isolation, Apple-specific session selection, Chinese input, app compatibility, lifetime across disconnect/lock/sleep, and resource usage remain **NOT RUN on a real user Mac**. GitHub compilation is not evidence for any of those outcomes.

## Primary engineering uncertainty

The ARD type-30 handshake is implemented and tested at the wire/crypto level. It is not yet known whether that handshake alone can bootstrap or select the desired virtual user desktop on the target macOS version. The demo does not implement a separately verified Apple-private graphical-session creation API. If a real connection stops at a login/session negotiation screen, that is an unfinished part of the implementation. The fail-closed witness gate must not be removed to conceal it.
