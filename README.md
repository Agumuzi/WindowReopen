# WindowReopen

English · [简体中文](README.zh-CN.md)

A minimal macOS window activation enhancer. Restore minimized windows, reopen closed windows, and automatically hand off focus — powered by native Swift and launchd.

WindowReopen runs as a free, MIT-licensed user LaunchAgent. macOS continues to provide the standard **Command–Tab** switcher, keyboard shortcuts, icons, and animations.

## What it does

- **Switch to an app with a minimized window.** If it has no visible window, WindowReopen sends the native reopen request. Apps that restore minimized windows retain control over which window comes back.
- **Switch to an app whose windows were all closed.** If the app is still running, it can respond to the reopen request by showing a new window or following its usual reopen behavior.
- **Close or minimize the last visible window of the foreground app.** Focus goes to the app that owns the frontmost eligible window still visible. When an app still has a visible window, focus stays under normal macOS control.
- **Leave the desktop empty.** If no other eligible window remains, WindowReopen activates Finder without requesting a new Finder window.

## How it works

The service receives activation notifications from `NSWorkspace` and uses public Core Graphics window metadata to check for onscreen windows. When no normal window is visible after a short delay, it asks Launch Services to reopen the already-running app. It checks for a foreground change before sending the request.

For focus handoff, it samples eligible foreground apps every 150 ms. It confirms the disappearance of the last visible window with two consecutive samples and uses the onscreen stacking order to choose the next app. It clears the observation on a Space transition and skips the reopen check for an activation it requested for handoff.

Finder keeps its native desktop, Dock, and Command–Tab behavior. Finder activations do not trigger WindowReopen's reopen logic, and losing the last Finder window does not trigger handoff. Finder remains eligible to receive focus, including when the desktop is empty.

## Requirements and compatibility

- **Apple Silicon (arm64)** and a native arm64 shell. Intel Macs are currently unsupported and untested.
- **macOS 13.0 or later** is the compiler deployment target. Runtime testing has been performed on an **Apple M1 Pro running macOS 27.2.1**.
- A working Swift toolchain from Xcode or the Xcode Command Line Tools. Check it with `xcrun --find swiftc`.
- Run the installer from your signed-in macOS GUI session as your regular user.

On that system, v1.1.1 tests covered window restoration and reopen with AppKit test windows, rapid programmatic switching, multiple windows, Finder window closure and minimization, Finder as a handoff target, the empty-desktop fallback, and a round trip between the ordinary desktop and fullscreen Dictionary. Clicking the bare desktop or Dock, the physical Command–Tab path, and switching between two ordinary Spaces remain unverified. Login startup has been checked through the LaunchAgent configuration and registration.

## Install from source

Download **Source code (zip)** or **Source code (tar.gz)** from the [Releases page](https://github.com/Agumuzi/WindowReopen/releases). Extract it, open a terminal in the extracted directory, and run `/bin/bash ./install.sh`.

You can also clone the repository:

~~~sh
git clone https://github.com/Agumuzi/WindowReopen.git
cd WindowReopen
/bin/bash ./install.sh
~~~

If you already use Command Reopen, quit it and turn off its login startup before installing. The installer checks for a running Command Reopen process.

The installer builds the executable locally, validates its architecture and the LaunchAgent configuration, and loads it into your GUI session. It installs the executable and source under `~/Library/Application Support/WindowReopen/` and uses `~/Library/LaunchAgents/local.windowreopen.plist` for login startup. Releases distribute source only.

## Check, pause, and resume

~~~sh
domain="gui/$(id -u)"
job="$domain/local.windowreopen"
agent="$HOME/Library/LaunchAgents/local.windowreopen.plist"

# Status and process
launchctl print "$job"
pgrep -lx window-reopen

# Pause for the current GUI session
launchctl bootout "$job"

# Resume from a paused state
launchctl bootstrap "$domain" "$agent"

# Restart an already loaded service
launchctl kickstart -k "$job"
~~~

To prevent startup at the next login, run `launchctl disable "$job"` and pause the service if loaded. Run `launchctl enable "$job"` before resuming.

## Update or uninstall

To update, extract a newer release and run its `/bin/bash ./install.sh`. If you are following the `main` branch of a clone, run `git pull --ff-only` first. The installer backs up the previous deployment in a sibling `WindowReopen-backup.*` directory. If startup fails during setup, it attempts to restore the previous files and reload the previous job.

~~~sh
/bin/bash "$HOME/Library/Application Support/WindowReopen/uninstall.sh"
~~~

Uninstall unloads the service and removes the project-managed installation files. It retains prior backups, your checkout, and extra files you placed in the installation directory. If extra files remain in that directory, move them elsewhere before reinstalling.

## Permissions and privacy

WindowReopen has no GUI, no Dock or menu bar icon, no telemetry, no runtime network communication, and no third-party runtime dependencies. It requires no Accessibility, Screen Recording, Input Monitoring, Automation, or Full Disk Access grants. It makes no system-file changes and runs without administrator privileges.

It reads window metadata such as ownership, bounds, visibility, and stacking order. Diagnostics use macOS Unified Logging and may include process IDs or error codes. They contain no window titles or document contents.

## Known limitations

- Activation notifications do not identify the source. Dock, Spotlight, and programmatic activations can also be eligible.
- Finder activations are excluded from automatic reopen, including when Command–Tab selects Finder without a window.
- Window metadata does not always distinguish minimized windows from windows outside the current screen or Space. App layouts, fullscreen transitions, and helper windows can affect detection.
- The target app chooses how to respond to a native reopen request and may ignore it. Handoff activates an app, and macOS and that app determine the exact window receiving focus.
- An app closing its own last window can trigger handoff, as can a keyboard shortcut. A handoff naturally updates the macOS app switcher's recent-use order.

## Credits and license

The native reopen approach and window heuristic were adapted from [Command Reopen](https://github.com/Feng6611/mac-command-reopen) 1.5.5 at [commit `011eba15`](https://github.com/Feng6611/mac-command-reopen/commit/011eba15baf6cd0ff5c9245aa96431701f90a602). Thanks to Chen for publishing the upstream implementation.

Released under the [MIT License](LICENSE). The upstream notice, **Copyright (c) 2025 Chen**, is retained.
