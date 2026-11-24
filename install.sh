#!/bin/bash
set -euo pipefail
umask 022

package="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
label=local.windowreopen
support="$HOME/Library/Application Support"
root="$support/WindowReopen"
plist="$HOME/Library/LaunchAgents/$label.plist"
uid="$(/usr/bin/id -u)"
domain="gui/$uid"
job="$domain/$label"
stage=
backup=
restore_job=0
installed_root=0
installed_plist=0
bootstrap_attempted=0
committed=0

fail() { printf '%s\n' "$*" >&2; exit 1; }
exists() { [[ -e "$1" || -L "$1" ]]; }

cleanup() {
    local status=$?
    if (( ! committed )); then
        if (( bootstrap_attempted )) && /bin/launchctl print "$job" >/dev/null 2>&1; then
            if ! /bin/launchctl bootout "$job"; then
                printf 'Rollback stopped: unable to unload %s. Backup: %s\n' "$job" "$backup" >&2
                return "$status"
            fi
        fi
        if (( installed_plist )); then /bin/rm -f -- "$plist"; fi
        if (( installed_root )); then /bin/mv -- "$root" "$stage/failed-install"; fi
        if [[ -n "$backup" ]]; then
            if [[ -d "$backup/WindowReopen" ]]; then /bin/mv -- "$backup/WindowReopen" "$root"; fi
            if [[ -f "$backup/$label.plist" ]]; then /bin/mv -- "$backup/$label.plist" "$plist"; fi
        fi
        if (( restore_job )); then
            /bin/launchctl bootstrap "$domain" "$plist" ||
                printf 'Previous service needs manual bootstrap: %s\n' "$plist" >&2
        fi
    fi
    if [[ -n "$stage" ]]; then /bin/rm -rf -- "$stage"; fi
    return "$status"
}

[[ "$uid" != 0 && "$(/usr/bin/stat -f %u /dev/console)" == "$uid" ]] ||
    fail 'Run in the signed-in user GUI session without sudo.'
[[ "$(/usr/bin/uname -m)" == arm64 ]] || fail 'Run on Apple Silicon in a native arm64 shell.'
macos="$(/usr/bin/sw_vers -productVersion)"
[[ "${macos%%.*}" -ge 13 ]] || fail 'macOS 13 or later is required.'
/bin/launchctl print "$domain" >/dev/null
if [[ "${WINDOWREOPEN_DEPLOYMENT_LOCKED:-}" != 1 ]]; then
    script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/install.sh"
    lock="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)local.windowreopen-install.lock"
    exec /usr/bin/lockf -t 0 "$lock" /usr/bin/env WINDOWREOPEN_DEPLOYMENT_LOCKED=1 /bin/bash "$script"
fi
/usr/bin/xcrun --find swiftc >/dev/null
if /usr/bin/pgrep -x 'Command Reopen' >/dev/null; then
    fail 'Quit Command Reopen before starting WindowReopen.'
fi
if /bin/launchctl print-disabled "$domain" | /usr/bin/awk -v label="\"$label\"" '
    $1 == label && $3 == "disabled" { found=1 } END { exit !found }'; then
    fail "Service is disabled. To resume it, run: launchctl enable '$job'"
fi
if exists "$root"; then
    [[ -d "$root" && ! -L "$root" && -O "$root" && -f "$root/.windowreopen" &&
       ! -L "$root/.windowreopen" && "$(/bin/cat "$root/.windowreopen")" == "$label" ]] ||
        fail "Unrecognized directory at $root. Move it aside before installation."
fi
if exists "$plist"; then
    [[ -f "$plist" && ! -L "$plist" && -O "$plist" &&
       "$(/usr/bin/plutil -extract Label raw -o - "$plist")" == "$label" &&
       "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$plist")" == "$root/window-reopen" ]] ||
        fail "Conflicting LaunchAgent at $plist."
fi
loaded=0
if job_info="$(/bin/launchctl print "$job" 2>/dev/null)"; then
    loaded=1
    [[ -f "$plist" && -f "$root/.windowreopen" &&
       "$job_info" == *"path = $plist"$'\n'* &&
       "$job_info" == *"program = $root/window-reopen"$'\n'* ]] ||
        fail "Existing launchd job $job has a different origin."
fi

/bin/mkdir -p -- "$support" "$HOME/Library/LaunchAgents"
stage="$(/usr/bin/mktemp -d "$support/.WindowReopen-install.XXXXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Building WindowReopen for macOS %s (arm64)\n' "$macos"
/bin/mkdir -p -- "$stage/WindowReopen/source"
/bin/cp -- "$package/source/main.swift" "$stage/WindowReopen/source/main.swift"
/bin/cp -- "$package/install.sh" "$package/uninstall.sh" "$package/README.md" "$package/LICENSE" \
    "$package/$label.plist" "$stage/WindowReopen/"
/bin/chmod 755 "$stage/WindowReopen/install.sh" "$stage/WindowReopen/uninstall.sh"
printf '%s\n' "$label" > "$stage/WindowReopen/.windowreopen"
/usr/bin/xcrun swiftc -warnings-as-errors -O -target arm64-apple-macosx13.0 \
    "$stage/WindowReopen/source/main.swift" -o "$stage/WindowReopen/window-reopen"
/usr/bin/lipo -verify_arch arm64 "$stage/WindowReopen/window-reopen"
/usr/bin/codesign --verify --strict "$stage/WindowReopen/window-reopen"
"$stage/WindowReopen/window-reopen" --version
/bin/cp -- "$package/$label.plist" "$stage/$label.plist"
/usr/bin/plutil -replace ProgramArguments -json '[]' "$stage/$label.plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$root/window-reopen" "$stage/$label.plist"
/usr/bin/plutil -lint "$stage/$label.plist"

if exists "$root" || exists "$plist"; then
    backup="$(/usr/bin/mktemp -d "$support/WindowReopen-backup.XXXXXXXX")"
    printf 'Previous files will be kept at %s\n' "$backup"
fi
if (( loaded )); then
    /bin/launchctl bootout "$job"
    restore_job=1
fi
if exists "$root"; then /bin/mv -- "$root" "$backup/WindowReopen"; fi
if exists "$plist"; then /bin/mv -- "$plist" "$backup/$label.plist"; fi
/bin/mv -- "$stage/WindowReopen" "$root"
installed_root=1
/bin/mv -- "$stage/$label.plist" "$plist"
installed_plist=1
bootstrap_attempted=1
/bin/launchctl bootstrap "$domain" "$plist"

for (( attempt=0; attempt<30; attempt++ )); do
    pid="$(/bin/launchctl print "$job" | /usr/bin/awk '$1=="pid" && $2=="=" { print $3 }')"
    if [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$pid" 2>/dev/null; then
        committed=1
        printf 'Running: %s (PID %s)\n' "$job" "$pid"
        /usr/bin/shasum -a 256 "$root/window-reopen"
        exit 0
    fi
    /bin/sleep 0.2
done
fail "Service did not start: $job"
