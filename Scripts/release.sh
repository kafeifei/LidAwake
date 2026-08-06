#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
version="$(<"$project_dir/VERSION")"
output_directory="$project_dir/dist"
archive_path="$output_directory/LidAwake-$version.zip"

if [[ -z "${LIDAWAKE_SIGN_IDENTITY:-}" ]]; then
    print -u2 "Set LIDAWAKE_SIGN_IDENTITY to a Developer ID Application certificate."
    exit 1
fi
if [[ -z "${LIDAWAKE_NOTARY_PROFILE:-}" ]]; then
    print -u2 "Set LIDAWAKE_NOTARY_PROFILE to a notarytool keychain profile."
    exit 1
fi

case "$output_directory" in
    "$project_dir"/dist) ;;
    *) print -u2 "Unexpected output directory: $output_directory"; exit 1 ;;
esac

LIDAWAKE_ARCHS="arm64 x86_64" "$project_dir/Scripts/build-app.sh" release
/bin/mkdir -p "$output_directory"
/bin/rm -f "$archive_path"
/usr/bin/ditto -c -k --keepParent "$project_dir/.build/LidAwake.app" "$archive_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$project_dir/.build/LidAwake.app"
/usr/bin/xcrun notarytool submit "$archive_path" \
    --keychain-profile "$LIDAWAKE_NOTARY_PROFILE" \
    --wait
/usr/bin/xcrun stapler staple "$project_dir/.build/LidAwake.app"
/bin/rm -f "$archive_path"
/usr/bin/ditto -c -k --keepParent "$project_dir/.build/LidAwake.app" "$archive_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$project_dir/.build/LidAwake.app"
/usr/bin/shasum -a 256 "$archive_path" > "$archive_path.sha256"

print "$archive_path"
