# Changelog

This repository's documentation and installers. The CLI's own changes are in
the GaiaDesk release notes.

## Unreleased

- `docs/commands.md`: every command, generated from `gaiadesk-cli 0.10.358`'s
  own help (was 0.10.328: alias, wake, presence, ping, status, desk, sync,
  pull-changed, tool, health, disk, connect, doctor, watch, changelog,
  init-agent and api were missing).
- `scripts/gen-cli-docs.mts` lives here; CI checks the reference against the
  latest release on every push and daily (`--check`).
- `install.sh` (macOS, Linux): OS and CPU detection (Rosetta installs the
  native arm64 build; musl stops with a hint), SHA-256 check, `gaiadesk-cli`
  plus a `gaiadesk` symlink into `~/.local/bin`, `--dir`, `--global`
  (`/usr/local/bin`), `GAIADESK_VERSION` to pin a release.
- `install.ps1` (Windows): the same into `%LOCALAPPDATA%\GaiaDesk\bin`, added
  to the user `PATH`; `gaiadesk.exe` is a hard link to `gaiadesk-cli.exe`.
- `GAIADESK_DOWNLOAD_BASE` points either installer at a mirror.
- CI: shellcheck, PSScriptAnalyzer, and both installers against a fake local
  release.
