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

if [[ -n "${LIDAWAKE_SPARKLE_BIN:-}" ]]; then
    generate_appcast="$LIDAWAKE_SPARKLE_BIN/generate_appcast"
else
    /usr/bin/swift package --package-path "$project_dir" resolve
    typeset -a generate_appcast_matches
    generate_appcast_matches=($project_dir/.build/artifacts/**/bin/generate_appcast(N.))
    if (( ${#generate_appcast_matches} != 1 )); then
        print -u2 "Expected exactly one generate_appcast under .build/artifacts, found ${#generate_appcast_matches}."
        print -u2 "Set LIDAWAKE_SPARKLE_BIN to the directory holding Sparkle's generate_appcast."
        exit 1
    fi
    generate_appcast="${generate_appcast_matches[1]}"
fi
if [[ ! -x "$generate_appcast" ]]; then
    print -u2 "generate_appcast is not executable: $generate_appcast"
    exit 1
fi

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
(cd "$output_directory" && /usr/bin/shasum -a 256 "$(basename "$archive_path")" > "$archive_path.sha256")

appcast_path="$output_directory/appcast.xml"
# generate_appcast signs every archive it finds, so scan a staging directory holding only
# this run's archive; older releases left in dist/ would otherwise add bogus appcast items
# and binary deltas.
staging_directory="$output_directory/appcast-staging"
case "$staging_directory" in
    "$project_dir"/dist/appcast-staging) ;;
    *) print -u2 "Unexpected staging directory: $staging_directory"; exit 1 ;;
esac
/bin/rm -rf "$staging_directory"
/bin/mkdir -p "$staging_directory"
/bin/ln "$archive_path" "$staging_directory/" 2>/dev/null || /bin/cp "$archive_path" "$staging_directory/"
# An appcast left by an earlier run would otherwise keep contributing its stale items.
/bin/rm -f "$appcast_path"
# The EdDSA private key comes from the login keychain.
"$generate_appcast" \
    --download-url-prefix "https://github.com/kafeifei/LidAwake/releases/download/v$version/" \
    --link "https://github.com/kafeifei/LidAwake/releases" \
    -o "$appcast_path" \
    "$staging_directory"
/bin/rm -rf "$staging_directory"

print "$archive_path"
print "$appcast_path"
