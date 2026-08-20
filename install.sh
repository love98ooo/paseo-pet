#!/bin/sh
set -eu

install_dir=${1:-"$HOME/Applications"}
app_path="$install_dir/Paseo Pet.app"
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
codesign_identity=${PASEO_CODESIGN_IDENTITY:-"Paseo Pet Local Development"}

identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
if ! printf '%s\n' "$identities" | awk -v target="$codesign_identity" '
    /^[[:space:]]*[0-9]+\)/ {
        split($0, fields, "\"")
        if ($2 == target || fields[2] == target) found = 1
    }
    END { exit found ? 0 : 1 }
'; then
    printf >&2 'Code signing identity "%s" was not found.\n' "$codesign_identity"
    printf >&2 'Create or import it in Keychain Access, or set PASEO_CODESIGN_IDENTITY.\n\n%s\n' "$identities"
    exit 1
fi

cd "$script_dir"
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)

install -d "$install_dir"
staging_dir=$(mktemp -d "$install_dir/.paseo-pet-install.XXXXXX")
staged_app="$staging_dir/Paseo Pet.app"
previous_app="$staging_dir/Paseo Pet.previous.app"
failed_app="$staging_dir/Paseo Pet.failed.app"
swap_started=0
new_in_place=0
had_previous=0
committed=0

cleanup() {
    status=$?
    cleanup_staging=1
    trap - EXIT HUP INT TERM
    if [ "$committed" -ne 1 ] && [ "$swap_started" -eq 1 ]; then
        if [ "$new_in_place" -eq 1 ] && [ -e "$app_path" ]; then
            if ! mv "$app_path" "$failed_app"; then
                cleanup_staging=0
            fi
        fi
        if [ "$had_previous" -eq 1 ] && [ -e "$previous_app" ]; then
            if [ -e "$app_path" ]; then
                cleanup_staging=0
            elif ! mv "$previous_app" "$app_path"; then
                cleanup_staging=0
            fi
        fi
    fi
    if [ "$cleanup_staging" -eq 1 ]; then
        case "$staging_dir" in
            "$install_dir"/.paseo-pet-install.*) rm -rf "$staging_dir" ;;
        esac
    else
        printf >&2 'Rollback incomplete; backup retained in: %s\n' "$staging_dir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

install -d "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 755 "$bin_dir/PaseoPet" "$staged_app/Contents/MacOS/PaseoPet"
install -m 644 "$script_dir/Assets/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"

cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PaseoPet</string>
    <key>CFBundleIdentifier</key>
    <string>sh.paseo.pet</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Paseo Pet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --timestamp=none --sign "$codesign_identity" "$staged_app"
codesign --verify --strict --verbose=2 "$staged_app"

process_path="$app_path/Contents/MacOS/PaseoPet"
running_pids() {
    ps -ww -axo pid=,command= | awk -v target="$process_path" '{
        pid = $1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
        if ($0 == target || index($0, target " ") == 1) print pid
    }'
}

pids=$(running_pids)
if [ -n "$pids" ]; then
    printf 'Stopping the running PaseoPet process...\n'
    kill -TERM $pids || true
    attempts=0
    while [ -n "$(running_pids)" ] && [ "$attempts" -lt 5 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
    if [ -n "$(running_pids)" ]; then
        printf >&2 'PaseoPet is still running; installation stopped before replacing the app.\n'
        exit 1
    fi
fi

swap_started=1
if [ -e "$app_path" ]; then
    had_previous=1
    mv "$app_path" "$previous_app"
fi
new_in_place=1
mv "$staged_app" "$app_path"
codesign --verify --strict --verbose=2 "$app_path"
touch "$app_path"
committed=1

printf '\nInstalled Paseo Pet at:\n  %s\n\nOpen with:\n  open "%s"\n' "$app_path" "$app_path"
