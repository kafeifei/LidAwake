# Contributing

Thanks for helping improve LidAwake.

## Before opening a pull request

1. Keep changes focused on the reported behavior.
2. Do not broaden the root helper beyond power-source detection, `pmset disablesleep`, configuration reads, and status writes.
3. Add or update tests for policy, parsing, path, or serialization changes.
4. Run `./Scripts/check.sh` and include any manual hardware A/B checks in the pull request description.

Changes involving helper installation, administrator authorization, private APIs, or shell command construction require an explicit security explanation.

Use GitHub private vulnerability reporting instead of a public issue for security-sensitive findings.
