set helperPath to quoted form of "/Library/PrivilegedHelperTools/com.kafeifei.LidAwake.helper"
set daemonPath to quoted form of "/Library/LaunchDaemons/com.kafeifei.LidAwake.helper.plist"
set statusPath to quoted form of "/Library/Application Support/LidAwake/status.json"
set supportPath to quoted form of "/Library/Application Support/LidAwake"
set commandText to "set -e; " & ¬
    "/bin/launchctl bootout system/com.kafeifei.LidAwake.helper >/dev/null 2>&1 || true; " & ¬
    "/usr/bin/pmset disablesleep 0; " & ¬
    "/bin/rm -f " & helperPath & " " & daemonPath & " " & statusPath & "; " & ¬
    "/bin/rmdir " & supportPath & " >/dev/null 2>&1 || true"
do shell script commandText with administrator privileges
