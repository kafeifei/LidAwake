on run argv
    set helperPath to quoted form of "/Library/PrivilegedHelperTools/com.kafeifei.LidAwake.helper"
    set daemonPath to quoted form of "/Library/LaunchDaemons/com.kafeifei.LidAwake.helper.plist"
    set statusPath to quoted form of "/Library/Application Support/LidAwake/status.json"
    set supportPath to quoted form of "/Library/Application Support/LidAwake"
    set commandText to "set -e; " & ¬
        "/bin/launchctl bootout system/com.kafeifei.LidAwake.helper >/dev/null 2>&1 || true; " & ¬
        "/usr/bin/pmset disablesleep 0; " & ¬
        "/bin/rm -f " & helperPath & " " & daemonPath & " " & statusPath & "; " & ¬
        "/bin/rmdir " & supportPath & " >/dev/null 2>&1 || true"

    -- 可选参数：当前用户无权删除的应用本体，和系统组件在同一次授权里删除。
    if (count of argv) > 0 then
        set appPath to item 1 of argv
        if appPath does not end with "/LidAwake.app" then
            error "拒绝删除无法验证的应用：" & appPath number 1
        end if
        set bundleIdentifier to do shell script ¬
            "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' " & ¬
            quoted form of (appPath & "/Contents/Info.plist") & " 2>/dev/null || true"
        if bundleIdentifier is not "com.kafeifei.LidAwake" then
            error "拒绝删除无法验证的应用：" & appPath number 1
        end if
        set commandText to commandText & "; /bin/rm -rf " & quoted form of appPath
    end if

    do shell script commandText with administrator privileges
end run
