# Security

## Privileged behavior

LidAwake installs `LidAwakeHelper` as a root LaunchDaemon. The helper has a deliberately narrow responsibility: read the configured policy and power source, run `/usr/bin/pmset disablesleep 0|1`, and write a status file.

The application does not download or execute remote content. Installation and removal require explicit macOS administrator authorization.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting for issues involving privilege boundaries, installation, or command execution. Do not publish exploit details in a public issue before a fix is available.

For ordinary bugs that do not involve a security boundary, open a regular GitHub issue with the macOS version, Mac model, and reproduction steps.
