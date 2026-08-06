#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="$project_dir/.build/LidAwake.app"
user_home="${HOME:A}"
destination_dir="$user_home/Applications"
destination_app="$destination_dir/LidAwake.app"
destination_executable="$destination_app/Contents/MacOS/LidAwake"
launch_agent_plist="$user_home/Library/LaunchAgents/com.kafeifei.LidAwake.menu.plist"
launch_agent_label="com.kafeifei.LidAwake.menu"
user_domain="gui/$(/usr/bin/id -u)"

stop_installed_app() {
    local attempt process_pid running_command still_running
    for process_pid in ${(@f)"$(/usr/bin/pgrep -x LidAwake 2>/dev/null || true)"}; do
        [[ -n "$process_pid" ]] || continue
        running_command="$(/bin/ps -ww -p "$process_pid" -o command= 2>/dev/null || true)"
        if [[ "$running_command" == "$destination_executable" ]]; then
            /bin/kill -TERM "$process_pid" >/dev/null 2>&1 || true
        fi
    done

    for attempt in {1..30}; do
        still_running=false
        for process_pid in ${(@f)"$(/usr/bin/pgrep -x LidAwake 2>/dev/null || true)"}; do
            [[ -n "$process_pid" ]] || continue
            running_command="$(/bin/ps -ww -p "$process_pid" -o command= 2>/dev/null || true)"
            [[ "$running_command" == "$destination_executable" ]] && still_running=true
        done
        [[ "$still_running" == false ]] && return
        /bin/sleep 0.1
    done

    print -u2 "LidAwake 仍在运行，请退出菜单栏应用后重试。"
    exit 1
}

"$project_dir/Scripts/build-app.sh" release
/bin/mkdir -p "$destination_dir"

case "$destination_app" in
    "$user_home"/Applications/LidAwake.app) ;;
    *) print -u2 "Unexpected destination: $destination_app"; exit 1 ;;
esac

/bin/launchctl bootout "$user_domain/$launch_agent_label" >/dev/null 2>&1 || true
/bin/rm -f "$launch_agent_plist"
stop_installed_app
/bin/rm -rf "$destination_app"
/usr/bin/ditto "$source_app" "$destination_app"
/usr/bin/open "$destination_app"

print "$destination_app"
