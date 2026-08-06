#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
version="$(<"$project_dir/VERSION")"
build_number="${LIDAWAKE_BUILD_NUMBER:-1}"
sign_identity="${LIDAWAKE_SIGN_IDENTITY:--}"
typeset -a architecture_arguments

if [[ -n "${LIDAWAKE_ARCHS:-}" ]]; then
    for build_architecture in ${(z)LIDAWAKE_ARCHS}; do
        case "$build_architecture" in
            arm64|x86_64) architecture_arguments+=(--arch "$build_architecture") ;;
            *) print -u2 "Unsupported architecture: $build_architecture"; exit 1 ;;
        esac
    done
fi

cd "$project_dir"
/usr/bin/swift build -c "$configuration" "${architecture_arguments[@]}" -Xswiftc -warnings-as-errors --product LidAwakeApp
/usr/bin/swift build -c "$configuration" "${architecture_arguments[@]}" -Xswiftc -warnings-as-errors --product LidAwakeHelper

bin_dir="$(/usr/bin/swift build -c "$configuration" "${architecture_arguments[@]}" --show-bin-path)"
app_bundle="$project_dir/.build/LidAwake.app"

case "$app_bundle" in
    "$project_dir"/.build/LidAwake.app) ;;
    *) print -u2 "Unexpected app bundle path: $app_bundle"; exit 1 ;;
esac

/bin/rm -rf "$app_bundle"
/bin/mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
/usr/bin/install -m 0755 "$bin_dir/LidAwakeApp" "$app_bundle/Contents/MacOS/LidAwake"
/usr/bin/install -m 0755 "$bin_dir/LidAwakeHelper" "$app_bundle/Contents/Resources/LidAwakeHelper"
/usr/bin/install -m 0644 "$project_dir/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
/usr/bin/install -m 0644 "$project_dir/Resources/com.kafeifei.LidAwake.helper.plist" "$app_bundle/Contents/Resources/com.kafeifei.LidAwake.helper.plist"
/usr/bin/install -m 0644 "$project_dir/LICENSE" "$app_bundle/Contents/Resources/LICENSE"
/usr/bin/install -m 0644 "$project_dir/THIRD_PARTY_NOTICES.md" "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/bin/install -m 0755 "$project_dir/Scripts/uninstall.sh" "$app_bundle/Contents/Resources/uninstall.sh"
/usr/bin/install -m 0644 "$project_dir/Scripts/uninstall-privileged.applescript" "$app_bundle/Contents/Resources/uninstall-privileged.applescript"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$app_bundle/Contents/Info.plist"

typeset -a codesign_arguments
codesign_arguments=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${codesign_arguments[@]}" "$app_bundle/Contents/Resources/LidAwakeHelper"
/usr/bin/codesign "${codesign_arguments[@]}" "$app_bundle"

print "$app_bundle"
