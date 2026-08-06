#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

if /usr/bin/grep -n "/Users/" \
    Sources/**/*.swift \
    Resources/*.plist \
    Scripts/build-app.sh \
    Scripts/install-app.sh \
    Scripts/release.sh \
    Scripts/uninstall.sh \
    README.md \
    Package.swift; then
    print -u2 "Found a user-specific absolute path."
    exit 1
fi

/usr/bin/swift test -Xswiftc -warnings-as-errors
/bin/zsh -n Scripts/build-app.sh Scripts/check.sh Scripts/install-app.sh Scripts/release.sh Scripts/uninstall.sh
/usr/bin/osacompile -o .build/uninstall-privileged.scpt Scripts/uninstall-privileged.applescript
/usr/bin/plutil -lint \
    Resources/Info.plist \
    Resources/com.kafeifei.LidAwake.helper.plist

"$project_dir/Scripts/build-app.sh" release
/usr/bin/codesign --verify --deep --strict "$project_dir/.build/LidAwake.app"

print "LidAwake checks passed."
