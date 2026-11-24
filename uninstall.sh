#!/bin/bash
set -euo pipefail

label=local.windowreopen
root="$HOME/Library/Application Support/WindowReopen"
plist="$HOME/Library/LaunchAgents/$label.plist"
uid="$(/usr/bin/id -u)"
domain="gui/$uid"
job="$domain/$label"

fail() { printf '%s\n' "$*" >&2; exit 1; }
exists() { [[ -e "$1" || -L "$1" ]]; }

[[ "$uid" != 0 ]] || fail 'Run as the installed user without sudo.'
/bin/launchctl print "$domain" >/dev/null
if [[ "${WINDOWREOPEN_DEPLOYMENT_LOCKED:-}" != 1 ]]; then
    script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/uninstall.sh"
    lock="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)local.windowreopen-install.lock"
    exec /usr/bin/lockf -t 0 "$lock" /usr/bin/env WINDOWREOPEN_DEPLOYMENT_LOCKED=1 /bin/bash "$script"
fi
if exists "$root"; then
    if [[ -d "$root" && ! -L "$root" && -O "$root" ]] &&
       ! exists "$root/.windowreopen" && ! exists "$plist" &&
       ! /bin/launchctl print "$job" >/dev/null 2>&1; then
        printf 'No WindowReopen installation was found. Left the existing directory untouched: %s\n' "$root"
        exit 0
    fi
    [[ -d "$root" && ! -L "$root" && -O "$root" && -f "$root/.windowreopen" &&
       ! -L "$root/.windowreopen" && "$(/bin/cat "$root/.windowreopen")" == "$label" ]] ||
        fail "Unrecognized directory at $root."
    [[ ! -L "$root/source" ]] || fail "Unexpected symbolic link at $root/source."
fi
if exists "$plist"; then
    [[ -f "$plist" && ! -L "$plist" && -O "$plist" &&
       "$(/usr/bin/plutil -extract Label raw -o - "$plist")" == "$label" &&
       "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$plist")" == "$root/window-reopen" ]] ||
        fail "Conflicting LaunchAgent at $plist."
fi
if job_info="$(/bin/launchctl print "$job" 2>/dev/null)"; then
    [[ "$job_info" == *"path = $plist"$'\n'* &&
       "$job_info" == *"program = $root/window-reopen"$'\n'* ]] ||
        fail "Existing launchd job $job has a different origin."
    /bin/launchctl bootout "$job"
fi
if exists "$root" || exists "$plist"; then
    if /bin/launchctl print-disabled "$domain" | /usr/bin/awk -v label="\"$label\"" '
        $1 == label && $3 == "disabled" { found=1 } END { exit !found }'; then
        /bin/launchctl enable "$job"
    fi
fi
if exists "$plist"; then /bin/rm -f -- "$plist"; fi
if exists "$root"; then
    /bin/rm -f -- "$root/window-reopen" "$root/install.sh" "$root/uninstall.sh" \
        "$root/README.md" "$root/LICENSE" "$root/$label.plist"
    if [[ -d "$root/source" ]]; then
        /bin/rm -f -- "$root/source/main.swift"
        /bin/rmdir -- "$root/source" 2>/dev/null || true
    fi
    /bin/rm -f -- "$root/.windowreopen"
    /bin/rmdir -- "$root" 2>/dev/null || printf 'Kept additional files at %s\n' "$root"
fi
printf '%s\n' 'WindowReopen is unloaded and installed files are removed.'
