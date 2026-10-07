# gaiadesk-cli

One tool to run commands, copy files, run jobs and drive screens on your
GaiaDesk computers ("desks"), from scripts, CI and AI agents.

```sh
gaiadesk devices                                # the desks you can reach
gaiadesk exec -d 123456789 -- uname -a          # one command, its real exit code
gaiadesk cp ./build.tar.gz 123456789:deploy/    # copy files, resumably
gaiadesk run --detach --name build --desk-id 123456789 -- 'make -j8'   # a job that outlives you
gaiadesk mcp                                    # the same tools for an AI assistant
```

`gaiadesk` and `gaiadesk-cli` are the same program; every example works with
either name.

This repository holds the CLI's documentation and installers. The CLI itself
ships as a prebuilt binary on
[GaiaDesk releases](https://github.com/Gaia-Desk/gaiadesk-releases/releases).
GaiaDesk is closed-source; nothing here is GaiaDesk code.

- [Install](#install)
- [Sign in, and scoped agent tokens](#sign-in-and-scoped-agent-tokens)
- [A quick tour](#a-quick-tour)
- [JSON output and errors](#json-output-and-errors)
- [Command reference](docs/commands.md)
- [SDKs and MCP](#sdks-and-mcp)
- [License](#license)

## Install

**npm** (Node.js 18+; installs the right binary for your platform):

```sh
npm install -g @gaiadesk/cli
gaiadesk --version

# or without installing
npx @gaiadesk/cli devices
```

**macOS and Linux** (installs into `~/.local/bin`):

```sh
curl -fsSL https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.sh | sh
```

- `| sh -s -- --global` installs into `/usr/local/bin` (using sudo when needed).
- `GAIADESK_INSTALL=/opt/bin` picks another directory.
- `GAIADESK_VERSION=0.10.325` pins a release (the default is the latest).

The script detects your OS and CPU (an Intel shell under Rosetta gets the
native Apple silicon build), downloads the archive and its `.sha256`, checks
the checksum, and installs `gaiadesk-cli` plus a `gaiadesk` symlink. It
prints a hint if the directory is not on your `PATH`; it never edits your
shell profile. Linux builds need glibc: on musl (Alpine) it stops and says
so.

**Windows** (PowerShell; installs into `%LOCALAPPDATA%\GaiaDesk\bin` and adds
it to your user `PATH`, no administrator rights needed):

```powershell
irm https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.ps1 | iex
```

`$env:GAIADESK_VERSION` and `$env:GAIADESK_INSTALL` work as above. Open a new
terminal afterwards so it sees the new `PATH`.

**Homebrew** (macOS and Linux):

```sh
brew install gaia-desk/tap/gaiadesk
```

**Direct download.** Each release has, for `darwin-arm64`, `darwin-x64`,
`linux-x64`, `linux-arm64`, `windows-x64` and `windows-arm64`:

| Asset | |
| --- | --- |
| `gaiadesk-cli-<version>-<os>-<arch>.tar.gz` (`.zip` on Windows) | that version |
| `gaiadesk-cli-<os>-<arch>.tar.gz` (`.zip` on Windows) | the same, under a name that stays stable |
| `<asset>.sha256` | its SHA-256 and file name |

The latest release is always at
`https://github.com/Gaia-Desk/gaiadesk-releases/releases/latest/download/<asset>`.
Each archive holds `gaiadesk-cli` (`gaiadesk-cli.exe`) at its root:

```sh
curl -fsSLO https://github.com/Gaia-Desk/gaiadesk-releases/releases/latest/download/gaiadesk-cli-linux-x64.tar.gz
curl -fsSLO https://github.com/Gaia-Desk/gaiadesk-releases/releases/latest/download/gaiadesk-cli-linux-x64.tar.gz.sha256
sha256sum -c gaiadesk-cli-linux-x64.tar.gz.sha256
tar -xzf gaiadesk-cli-linux-x64.tar.gz && ./gaiadesk-cli --version
```

The GaiaDesk desktop app also includes `gaiadesk-cli`; you only need one of
them.

## Sign in, and scoped agent tokens

The machines you reach are desks running GaiaDesk. Sign this machine's CLI
in to your GaiaDesk account (it shows a code to approve in any browser, so
it works over SSH and on headless machines too):

```sh
gaiadesk login
gaiadesk devices            # your account's and your team's desks, paired and Mesh ones
gaiadesk devices --probe    # dial each one now: does a command really get through?
```

A command that reaches a desk presents one credential, chosen in this order:

| Credential | |
| --- | --- |
| `--token-file <file>` | a scoped agent token (below) |
| `$GAIADESK_TOKEN_FILE` | the same, from the environment |
| `$GAIADESK_CODE` | the desk's code or password |
| a prompt | only on a terminal; without one the command fails and says why |

`--code <code>` works only together with `--allow-code-in-argv`, because
every user on a machine can read its command lines.

**Give scripts, CI and AI agents a scoped token, never the desk's
password.** The desk's owner mints one, limited in time, in what it may do,
and optionally to one directory:

```sh
gaiadesk token create --desk 123456789 --name ci --expires 7d \
  --scope exec,cp,jobs --cwd /srv/app --out ~/.config/gaiadesk/ci.token

export GAIADESK_TOKEN_FILE=~/.config/gaiadesk/ci.token
gaiadesk exec -d 123456789 -- make test
```

Scopes: `exec`, `shell`, `cp`, `forward`, `jobs`, `screen`. `--low-priv`
runs the token's commands as the desk's low-privilege agent user. The desk
enforces all of it. `gaiadesk token list` and `gaiadesk token revoke` manage
tokens (a revoke drops the token's sessions and stops its jobs at once), and
`gaiadesk audit --desk 123456789` shows what each token ran.

## A quick tour

**devices**: what you can reach, and whether commands get through.

```sh
gaiadesk devices --json | jq '.devices[] | {desk_id, online, reachable}'
```

**exec**: one command, like `ssh host cmd`. Stdout and stderr come back
separately and unaltered; the exit code is the command's own.

```sh
gaiadesk exec -d 123456789 --shell sh -- 'uname -a; df -h /'
gaiadesk exec -d 123456789 --shell pwsh -- 'Get-Service | Where-Object Status -eq Running'
gaiadesk exec -d 123456789 --cwd /srv/app --timeout 10m -- make test
```

**shell**: an interactive terminal, like `ssh host`, or a script piped in.

```sh
gaiadesk shell -d 123456789
gaiadesk shell -d 123456789 --shell sh < setup.sh
```

**cp**: copy files or folders either way, like `scp`. An interrupted copy
resumes when you run it again.

```sh
gaiadesk cp -r ./site 123456789:www/
gaiadesk cp 123456789:logs/app.log ./
```

**run, ps, logs, kill**: long work as a background job that belongs to the
desk, not to your connection. It keeps running after you disconnect, and
after GaiaDesk restarts.

```sh
gaiadesk run --detach --name nightly --desk-id 123456789 --priority low --mem 4G -- ./nightly.sh
gaiadesk ps --desk-id 123456789
gaiadesk logs nightly --desk-id 123456789 -f
gaiadesk kill nightly --desk-id 123456789
```

**forward**: a local port to a port on (or near) the desk, like `ssh -L`.

```sh
gaiadesk forward 123456789:5432 localhost:15432
```

**mcp**: the same tools (plus screenshots and input, with an agent token)
for an AI assistant, over the Model Context Protocol.

```sh
gaiadesk mcp                 # stdio, for Claude Desktop, Claude Code, Cursor, ...
gaiadesk mcp --http          # Streamable HTTP
```

Also: `stats` (CPU, memory, disks, uptime), `measure` (latency and clock
offset), `mesh` (GaiaDesk Mesh addresses), `disconnect` (drop a held
connection), `agent run` (drive a desk's screen with a model). Every command
has `--help`; all of them are in [docs/commands.md](docs/commands.md).

Connections are held for a while (`--persist`, default 10 minutes) so the
next command to the same desk skips the handshake.

## JSON output and errors

Every command that reaches a desk takes `--json` and prints one JSON
document on stdout (`exec --json-stream` and `logs -f --json` print one
event per line). The human-readable message always goes to stderr, so
stdout stays parseable.

When a command fails, the JSON is an error envelope:

```json
{"error":{"kind":"refused","message":"desk 123456789 refused the command: the token has no exec scope"}}
```

| `kind` | Meaning | Exit code |
| --- | --- | --- |
| `usage` | bad arguments | 255 |
| `refused` | the desk or server said no: credential, scope, permission | 254 |
| `unreachable` | offline, unknown desk, no route, timed out (`reason` says which) | 255 |
| `connection_lost` | the connection went away mid-request | 255 (`shell`: 253) |
| `failed` | allowed, but it did not succeed (no such job, a file failed) | 1 or 255 |
| `protocol` | the desk's GaiaDesk is too old for the request | 255 |

`exec` exits with the remote command's own code (124 if `--timeout` stopped
it, 130 on Ctrl-C). `gaiadesk help json` lists every shape, and
`gaiadesk schema --json` prints the JSON Schema of all of them; the SDKs
generate their types from it. `gaiadesk --version --json` lists the features
a script can test for.

## SDKs and MCP

- **TypeScript / Node.js**: [Gaia-Desk/gaiadesk-typescript](https://github.com/Gaia-Desk/gaiadesk-typescript) (`npm install @gaiadesk/sdk`)
- **Python**: [Gaia-Desk/gaiadesk-python](https://github.com/Gaia-Desk/gaiadesk-python) (`pip install gaiadesk`)
- **MCP server** for AI assistants: [Gaia-Desk/gaiadesk-mcp](https://github.com/Gaia-Desk/gaiadesk-mcp) (`npx -y @gaiadesk/mcp`)

## About this repository

- [`docs/commands.md`](docs/commands.md): every command, its options and
  examples. It is generated from the CLI's own `--help` output by
  `scripts/gen-cli-docs.mts` in GaiaDesk's release process and regenerated
  for each release, so it matches the binary; edit the help text, not this
  file.
- [`install.sh`](install.sh), [`install.ps1`](install.ps1): the installers
  above. CI runs shellcheck, PSScriptAnalyzer, and both installers against a
  fake local release (`test/`); `GAIADESK_DOWNLOAD_BASE` points them at
  another server or mirror.
- Homebrew formula: [Gaia-Desk/homebrew-tap](https://github.com/Gaia-Desk/homebrew-tap).

Bugs in the CLI itself: [GaiaDesk support](https://gaiadesk.net). Bugs in
the docs or installers: issues and pull requests here are welcome.

## License

The documentation and installer scripts in this repository are MIT-licensed
(see [LICENSE](LICENSE)). The `gaiadesk-cli` binary they install is
proprietary GaiaDesk software, distributed under the GaiaDesk binary
licence, and is not covered by the MIT license.
