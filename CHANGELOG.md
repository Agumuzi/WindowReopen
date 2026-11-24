# Changelog

## v1.1.0 — 2026-11-24

First public source release.

- Use native application reopen behavior to restore minimized windows or request a window for an app that is already running.
- Hand off focus when the foreground app loses its last visible window. Activate Finder without opening a window when there is no visible candidate.
- Install and remove the Apple Silicon user LaunchAgent with the included shell scripts.
- Let repeat uninstall succeed when the service and its files have already been removed and only user files remain.
- Include English and Simplified Chinese documentation and the upstream MIT notice.

The Swift deployment target is macOS 13.0. Runtime verification took place on an Apple M1 Pro running macOS 27.2.1.
