#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
user_home="${HOME:A}"
destination_app="$user_home/Applications/LidAwake.app"
bundled_app="${script_directory:h:h}"
launch_agent_plist="$user_home/Library/LaunchAgents/com.kafeifei.LidAwake.menu.plist"
launch_agent_label="com.kafeifei.LidAwake.menu"
user_domain="gui/$(/usr/bin/id -u)"
configuration_file="$user_home/Library/Application Support/LidAwake/config.json"
configuration_directory="${configuration_file:h}"

if [[ -f "$bundled_app/Contents/Info.plist" ]] && \
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundled_app/Contents/Info.plist" 2>/dev/null || true)" == "com.kafeifei.LidAwake" ]]; then
    destination_app="$bundled_app"
fi

if [[ -d "$destination_app" ]]; then
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination_app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "${destination_app:t}" != "LidAwake.app" || "$bundle_identifier" != "com.kafeifei.LidAwake" ]]; then
        print -u2 "拒绝删除无法验证的应用：$destination_app"
        exit 1
    fi
fi

app_executable="$destination_app/Contents/MacOS/LidAwake"
if [[ -x "$app_executable" ]]; then
    "$app_executable" --unregister-login-item >/dev/null 2>&1 || \
        print -u2 "警告：无法取消系统登录项，将继续卸载其余组件。"
fi

/usr/bin/osascript "$script_directory/uninstall-privileged.applescript"

/bin/launchctl bootout "$user_domain/$launch_agent_label" >/dev/null 2>&1 || true
/bin/rm -f "$launch_agent_plist"
/bin/rm -f "$configuration_file"
/bin/rmdir "$configuration_directory" >/dev/null 2>&1 || true

if [[ -d "$destination_app" ]]; then
    for process_pid in ${(@f)"$(/usr/bin/pgrep -x LidAwake 2>/dev/null || true)"}; do
        [[ -n "$process_pid" ]] || continue
        running_command="$(/bin/ps -ww -p "$process_pid" -o command= 2>/dev/null || true)"
        if [[ "$running_command" == "$app_executable" ]]; then
            /bin/kill -TERM "$process_pid" >/dev/null 2>&1 || true
        fi
    done
    /bin/rm -rf "$destination_app"
fi

print "LidAwake 已卸载，并已恢复正常睡眠设置。"
