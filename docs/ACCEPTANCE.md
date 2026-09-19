# Real macOS desktop acceptance

This is the completion criterion, not a reduced feature definition. Unit tests, an installed account, a listening VNC port or an input acknowledgement cannot substitute for it. Record macOS build, CPU architecture, screen layout/scale, application versions and commit SHA. Use disposable test data.

## A. Native desktop creation

From a host user that remains logged in and active, create a dedicated standard Box account using the reviewed setup script. Authorize Screen Sharing explicitly. Connect from UserBox and record whether a new Aqua session is actually created without changing the physical console user, activating a host login window, blanking the monitor or requiring a manual user switch.

The native desktop must render *inside UserBox*, not an external replacement viewer, and the witness must report the Box UID, a completed login and off-console state. Both fresh corner markers must pass. A stopped/blank view is a correctly rejected unsafe connection, **not success**. If ARD authentication succeeds but the witness never appears, diagnose Apple's graphical-login/session negotiation instead of loosening the gate.

## B. Real apps and files

Run `bash scripts/acceptance-macos.sh ub_demo` after verification and Agent ownership. Confirm that Finder opens in the Box and browses `/Users/Shared/UserBox/ub_demo`. Confirm that the timestamped text file opens in the account's real native editor. PID/launch acknowledgement alone is insufficient.

Using CLI actions selected from screenshots, edit the text, invoke the native Save/Save As dialog, choose a name, save, close and reopen it. Verify the saved bytes from the explicit shared folder. Repeat with one host-installed third-party application that the Box account can access. Test right-click menus, child windows, dialogs, scrolling, a drag operation and keyboard shortcuts.

## C. Concurrent host input

While the Box continuously clicks, types and navigates, keep a host-native editor focused and type a known sequence while moving the physical mouse. Verify the exact host text and record that the host cursor, focus and windows do not jump, lose keystrokes or receive Box text. Do not move host input into UserBox during this phase. Continue through Box menus, dialogs and application changes.

The current repository does not have a host event-tap recorder. A person must observe the host or use separately authorized instrumentation; do not claim an automated isolation PASS from screenshots alone.

## D. Ownership and lifecycle

Take Control in UserBox and verify that queued/new Agent mutations are rejected. Verify Unicode/Chinese composition, modifiers, mouse up/down, drag across the viewer edge and returning control. Test view resizing, occlusion, minimization, disconnect/reconnect and closing the viewer. Independently test lock/unlock and sleep/wake, recording whether the system preserves, suspends or tears down the session. A session change must revoke input, never switch it to the host.

The current UI manages one connected Box at a time. Multiple simultaneous Box viewers are not implemented or certified by this demo. Treat multi-Box support as an additional unfinished requirement, not a successful result of creating multiple accounts.

## E. Negative and privilege cases

Use a wrong Box password, a wrong account, a stopped helper, an unexpected console UID, malformed IPC and a stale challenge. Verify no display or input is accepted after a proof failure. Confirm host-account credentials never appear in command arguments, logs or config. Check explicit shared-folder permissions and that application launch requests cannot open arbitrary URLs or execute shell commands through the RPC endpoint.

Disconnecting with a held key/button, secure input, privileged prompts and system-level shortcuts require special scrutiny. Do not change global host security settings just to make an application test pass.

## F. Resource measurements

Measure host baseline, connected idle desktop, Finder, editor, active input, minimized viewing and reconnect. Record resident memory by PID, total process count, CPU, GPU, frame rate, screenshot time and input-to-observed-frame latency. Include both the app and the Box session's WindowServer/login processes. Report incremental and application costs separately; do not infer a per-Box MB value from sharing the kernel.

## Result record

Use PASS / FAIL / NOT RUN for each section. Overall success requires A–E plus measured F, with evidence tied to a commit and target system. Preserve private screenshots locally and publish only sanitized evidence. The initial implementation has **not** completed this real-machine procedure.
