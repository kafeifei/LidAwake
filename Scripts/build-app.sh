#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
version="$(<"$project_dir/VERSION")"
build_number="${LIDAWAKE_BUILD_NUMBER:-$version}"
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
/usr/bin/swift build -c "$configuration" "${architecture_arguments[@]}" -Xswiftc -warnings-as-errors \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    --product LidAwakeApp
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

# Generate all standard and Retina icon sizes from the approved transparent master.
iconset_dir="$project_dir/.build/AppIcon.iconset"
/bin/mkdir -p "$iconset_dir"
for icon_size in 16 32 128 256 512; do
    /usr/bin/sips -z "$icon_size" "$icon_size" "$project_dir/Resources/AppIcon.png" \
        --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$project_dir/Resources/AppIcon.png" \
        --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset_dir" --output "$app_bundle/Contents/Resources/AppIcon.icns"

typeset -a sparkle_framework_matches
sparkle_framework_matches=($project_dir/.build/artifacts/**/Sparkle.xcframework/macos-*/Sparkle.framework(N/))
if (( ${#sparkle_framework_matches} != 1 )); then
    print -u2 "Expected exactly one Sparkle.framework under .build/artifacts, found ${#sparkle_framework_matches}."
    print -u2 "Run 'swift package resolve' and retry."
    exit 1
fi
sparkle_framework="${sparkle_framework_matches[1]}"
bundled_sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
/bin/mkdir -p "$app_bundle/Contents/Frameworks"
/usr/bin/ditto "$sparkle_framework" "$bundled_sparkle_framework"

# SwiftPM links the app against the artifact directory. The bundle carries its own copy, so the
# absolute build-time rpath is removed; it never resolves on another machine.
typeset -a linked_rpaths
linked_rpaths=(${(f)"$(/usr/bin/otool -l "$app_bundle/Contents/MacOS/LidAwake" | /usr/bin/awk '/LC_RPATH/ { in_rpath = 1; next } in_rpath && $1 == "path" { print $2; in_rpath = 0 }')"})
for linked_rpath in "${linked_rpaths[@]}"; do
    case "$linked_rpath" in
        "$project_dir"/.build*)
            /usr/bin/install_name_tool -delete_rpath "$linked_rpath" "$app_bundle/Contents/MacOS/LidAwake" 2>/dev/null || true
            ;;
    esac
done

typeset -a codesign_arguments
codesign_arguments=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi
# Sparkle's nested helpers are signed from the inside out; --deep is never used.
typeset -a sparkle_components
sparkle_components=(
    "$bundled_sparkle_framework/Versions/B/XPCServices/Installer.xpc"
    "$bundled_sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
    "$bundled_sparkle_framework/Versions/B/Autoupdate"
    "$bundled_sparkle_framework/Versions/B/Updater.app"
    "$bundled_sparkle_framework"
)
for sparkle_component in "${sparkle_components[@]}"; do
    [[ -e "$sparkle_component" ]] || continue
    /usr/bin/codesign "${codesign_arguments[@]}" "$sparkle_component"
done
/usr/bin/codesign "${codesign_arguments[@]}" "$app_bundle/Contents/Resources/LidAwakeHelper"
/usr/bin/codesign "${codesign_arguments[@]}" "$app_bundle"

print "$app_bundle"
