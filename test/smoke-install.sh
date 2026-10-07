#!/bin/sh
# Smoke-test install.sh against a fake release served on localhost by
# `python3 -m http.server` (through GAIADESK_DOWNLOAD_BASE). The fake
# gaiadesk-cli is a shell script that prints a version, so this runs on any
# macOS or Linux machine without a real release.
#
#   sh test/smoke-install.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d 2>/dev/null || mktemp -d -t gdsmoke)
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$*"
}

sha256_line() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# fake_asset <dir> <name> <version>
fake_asset() {
  stage="$work/stage-$3"
  mkdir -p "$stage"
  printf '#!/bin/sh\necho "gaiadesk-cli %s"\n' "$3" > "$stage/gaiadesk-cli"
  chmod 755 "$stage/gaiadesk-cli"
  tar -czf "$1/$2" -C "$stage" gaiadesk-cli
  printf '%s  %s\n' "$(sha256_line "$1/$2")" "$2" > "$1/$2.sha256"
}

release="$work/release"
mkdir -p "$release"
for p in darwin-arm64 darwin-x64 linux-x64 linux-arm64; do
  fake_asset "$release" "gaiadesk-cli-$p.tar.gz" 9.9.9
  fake_asset "$release" "gaiadesk-cli-1.2.3-$p.tar.gz" 1.2.3
done

# A free port, then the server.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
(cd "$release" && exec python3 -m http.server "$port" --bind 127.0.0.1) >"$work/server.log" 2>&1 &
server_pid=$!
base="http://127.0.0.1:$port"
i=0
until curl -fsS "$base/gaiadesk-cli-linux-x64.tar.gz.sha256" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || fail "the test server did not start: $(cat "$work/server.log")"
  sleep 0.2
done

# 1. Latest (the stable alias) into GAIADESK_INSTALL.
bin="$work/bin"
GAIADESK_DOWNLOAD_BASE="$base" GAIADESK_INSTALL="$bin" sh "$root/install.sh" 2>"$work/out1" || fail "install: $(cat "$work/out1")"
[ -x "$bin/gaiadesk-cli" ] || fail "no $bin/gaiadesk-cli"
[ -L "$bin/gaiadesk" ] || fail "no gaiadesk symlink"
[ "$("$bin/gaiadesk" --version)" = "gaiadesk-cli 9.9.9" ] || fail "gaiadesk --version: $("$bin/gaiadesk" --version)"
grep -q 'checksum ok' "$work/out1" || fail "no checksum line: $(cat "$work/out1")"
grep -q 'is not on your PATH' "$work/out1" || fail "no PATH hint: $(cat "$work/out1")"
pass "latest installs gaiadesk-cli and the gaiadesk symlink, with a PATH hint"

# 2. Pinned with GAIADESK_VERSION (and a leading v), over the existing install, from stdin like `curl | sh`.
GAIADESK_DOWNLOAD_BASE="$base" GAIADESK_INSTALL="$bin" GAIADESK_VERSION=v1.2.3 sh <"$root/install.sh" 2>"$work/out2" || fail "pinned: $(cat "$work/out2")"
[ "$("$bin/gaiadesk-cli" --version)" = "gaiadesk-cli 1.2.3" ] || fail "pinned version: $("$bin/gaiadesk-cli" --version)"
pass "GAIADESK_VERSION pins the versioned asset (script read from stdin)"

# 3. --dir and --version flags through `sh -s --`.
GAIADESK_DOWNLOAD_BASE="$base" sh -s -- --dir "$work/bin2" --version 1.2.3 <"$root/install.sh" 2>"$work/out3" || fail "flags: $(cat "$work/out3")"
[ "$("$work/bin2/gaiadesk" --version)" = "gaiadesk-cli 1.2.3" ] || fail "--dir/--version"
PATH="$work/bin2:$PATH" GAIADESK_DOWNLOAD_BASE="$base" sh "$root/install.sh" --dir "$work/bin2" 2>"$work/out3b" || fail "reinstall"
if grep -q 'is not on your PATH' "$work/out3b"; then fail "PATH hint printed for a directory on PATH"; fi
pass "--dir/--version flags; no PATH hint when the directory is on PATH"

# 4. A bad checksum installs nothing.
bad="$work/bad"
mkdir -p "$bad"
cp "$release"/* "$bad/"
for f in "$bad"/gaiadesk-cli-*-*.tar.gz.sha256; do
  printf '%s  x\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$f"
done
if GAIADESK_DOWNLOAD_BASE="file://$bad" GAIADESK_INSTALL="$work/bin3" sh "$root/install.sh" 2>"$work/out4"; then
  fail "a checksum mismatch was installed"
fi
grep -q 'checksum mismatch' "$work/out4" || fail "no mismatch message: $(cat "$work/out4")"
[ ! -e "$work/bin3/gaiadesk-cli" ] || fail "a binary was left after a checksum mismatch"
pass "a checksum mismatch fails and installs nothing (file:// base)"

# 5. A version that is not there fails with a hint.
if GAIADESK_DOWNLOAD_BASE="$base" GAIADESK_INSTALL="$work/bin4" GAIADESK_VERSION=7.7.7 sh "$root/install.sh" 2>"$work/out5"; then
  fail "a missing version installed"
fi
grep -q 'is 7.7.7 a released version' "$work/out5" || fail "no hint: $(cat "$work/out5")"
pass "a missing version fails with a hint"

# 6. Bad arguments.
if sh "$root/install.sh" --bogus 2>"$work/out6"; then fail "--bogus accepted"; fi
grep -q 'unknown option' "$work/out6" || fail "no unknown-option message"
sh "$root/install.sh" --help 2>&1 | grep -q 'usage: install.sh' || fail "--help"
pass "unknown options are refused; --help prints usage"

echo "all install.sh smoke tests passed"
