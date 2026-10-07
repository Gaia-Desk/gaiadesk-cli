#!/bin/sh
# Install gaiadesk-cli on macOS or Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.sh | sh -s -- --global
#
# Options (after `sh -s --` when piped):
#   --global          install into /usr/local/bin (with sudo when needed)
#   --dir <dir>       install into <dir>
#   --version <x.y.z> install that release instead of the latest
#   -h, --help        this help
#
# Environment:
#   GAIADESK_VERSION=x.y.z    pin a release (same as --version)
#   GAIADESK_INSTALL=<dir>    where to install (default: ~/.local/bin)
#   GAIADESK_DOWNLOAD_BASE    a URL (or file:// path) holding the release assets,
#                             instead of GitHub releases (mirrors, tests)
#
# It downloads gaiadesk-cli-<os>-<arch>.tar.gz (or, pinned,
# gaiadesk-cli-<version>-<os>-<arch>.tar.gz) and its .sha256 from
# github.com/Gaia-Desk/gaiadesk-releases, checks the SHA-256, and installs
# gaiadesk-cli plus a `gaiadesk` symlink to it. Nothing else is changed: no
# shell profile edits, no services.

# Everything is inside main(), called on the last line, so a download cut
# short never runs half a script.

set -eu

REPO="Gaia-Desk/gaiadesk-releases"

say() {
  printf 'gaiadesk install: %s\n' "$*" >&2
}

die() {
  say "error: $*"
  exit 1
}

usage() {
  cat <<'EOF_USAGE'
Install gaiadesk-cli (and a `gaiadesk` symlink to it).

usage: install.sh [--global | --dir <dir>] [--version <x.y.z>]

  --global          install into /usr/local/bin (with sudo when needed)
  --dir <dir>       install into <dir> (default: $GAIADESK_INSTALL, else ~/.local/bin)
  --version <x.y.z> install that release (default: $GAIADESK_VERSION, else the latest)

Piped: curl -fsSL https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.sh | sh -s -- --global
EOF_USAGE
}

has() {
  command -v "$1" >/dev/null 2>&1
}

# The asset name's <os>-<arch>.
detect_platform() {
  os=$(uname -s 2>/dev/null || echo unknown)
  arch=$(uname -m 2>/dev/null || echo unknown)
  case "$os" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      die "this is Windows; use PowerShell instead:
  irm https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.ps1 | iex" ;;
    *) die "unsupported operating system: $os (gaiadesk-cli is built for macOS, Linux and Windows)" ;;
  esac
  case "$arch" in
    x86_64 | amd64) arch=x64 ;;
    arm64 | aarch64 | armv8* | arm64e) arch=arm64 ;;
    *) die "unsupported CPU architecture: $arch (gaiadesk-cli is built for x64 and arm64)" ;;
  esac

  # An Intel shell under Rosetta on an Apple silicon Mac: install the native
  # arm64 build, not the x64 one Rosetta would have to translate.
  if [ "$os" = darwin ] && [ "$arch" = x64 ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
      say "this shell runs under Rosetta; installing the native Apple silicon (arm64) build"
      arch=arm64
    fi
  fi

  # musl (Alpine and friends): the Linux builds need glibc.
  if [ "$os" = linux ] && is_musl; then
    if [ "${GAIADESK_ALLOW_MUSL:-}" != 1 ]; then
      die "this Linux uses musl libc (Alpine?), and gaiadesk-cli is built for glibc.
  Use a glibc-based system or image (Debian, Ubuntu, Fedora, ...), or on Alpine
  try 'apk add gcompat' and rerun with GAIADESK_ALLOW_MUSL=1 (not supported)."
    fi
    say "musl libc detected; continuing because GAIADESK_ALLOW_MUSL=1 (not supported)"
  fi
  PLATFORM="$os-$arch"
}

is_musl() {
  for f in /lib/ld-musl-*.so.1 /usr/lib/ld-musl-*.so.1; do
    [ -e "$f" ] && return 0
  done
  if has ldd && ldd --version 2>&1 | grep -qi musl; then
    return 0
  fi
  return 1
}

# download <url> <file>
download() {
  case "$1" in
    file://*)
      cp "${1#file://}" "$2" 2>/dev/null || return 1
      return 0 ;;
  esac
  if has curl; then
    curl -fsSL --retry 3 --proto '=https,http' -o "$2" "$1"
  elif has wget; then
    wget -q -O "$2" "$1"
  else
    die "neither curl nor wget is installed"
  fi
}

# sha256 of <file>, hex
sha256_of() {
  if has sha256sum; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif has shasum; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  elif has openssl; then
    openssl dgst -sha256 "$1" | sed 's/^.*= *//'
  else
    die "no sha256sum, shasum or openssl to check the download with"
  fi
}

lower() {
  printf '%s' "$1" | tr 'ABCDEF' 'abcdef'
}

path_hint() {
  case ":${PATH:-}:" in
    *":$1:"*) return 0 ;;
  esac
  shell_name=$(basename "${SHELL:-sh}")
  case "$shell_name" in
    zsh) rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    fish) rc="" ;;
    *) rc="$HOME/.profile" ;;
  esac
  say "$1 is not on your PATH. Add it:"
  if [ "$shell_name" = fish ]; then
    printf '\n  fish_add_path %s\n\n' "$1" >&2
  else
    # shellcheck disable=SC2016 # $PATH is for the user's rc file, unexpanded
    printf '\n  echo '\''export PATH="%s:$PATH"'\'' >> %s\n\n' "$1" "$rc" >&2
  fi
}

main() {
  version="${GAIADESK_VERSION:-}"
  dir="${GAIADESK_INSTALL:-}"
  global=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --global) global=1 ;;
      --dir) [ $# -ge 2 ] || die "--dir needs a directory"; dir="$2"; shift ;;
      --dir=*) dir="${1#--dir=}" ;;
      --version) [ $# -ge 2 ] || die "--version needs a version (x.y.z)"; version="$2"; shift ;;
      --version=*) version="${1#--version=}" ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  version="${version#v}"
  if [ -n "$version" ]; then
    case "$version" in
      *[!0-9A-Za-z.-]* | "" ) die "not a version: $version (expected x.y.z)" ;;
    esac
  fi

  if [ "$global" = 1 ]; then
    [ -z "$dir" ] || die "give --global or --dir/GAIADESK_INSTALL, not both"
    dir=/usr/local/bin
  fi
  if [ -z "$dir" ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set; set GAIADESK_INSTALL to the directory to install into"
    dir="$HOME/.local/bin"
  fi

  detect_platform

  if [ -n "$version" ]; then
    asset="gaiadesk-cli-$version-$PLATFORM.tar.gz"
    base="${GAIADESK_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$version}"
  else
    asset="gaiadesk-cli-$PLATFORM.tar.gz"
    base="${GAIADESK_DOWNLOAD_BASE:-https://github.com/$REPO/releases/latest/download}"
  fi
  base="${base%/}"

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t gaiadesk)
  trap 'rm -rf "$tmp"' EXIT
  trap 'rm -rf "$tmp"; exit 130' INT TERM

  say "downloading $asset${version:+ (version $version)}"
  download "$base/$asset" "$tmp/$asset" || die "could not download $base/$asset${version:+ (is $version a released version?)}"
  download "$base/$asset.sha256" "$tmp/$asset.sha256" || die "could not download $base/$asset.sha256"

  want=$(lower "$(sed -n '1s/^\([0-9A-Fa-f]\{64\}\).*/\1/p' "$tmp/$asset.sha256")")
  [ -n "$want" ] || die "$asset.sha256 does not hold a SHA-256"
  got=$(lower "$(sha256_of "$tmp/$asset")")
  if [ "$want" != "$got" ]; then
    die "checksum mismatch for $asset: expected $want, got $got. Nothing was installed."
  fi
  say "checksum ok"

  mkdir "$tmp/x"
  tar -xzf "$tmp/$asset" -C "$tmp/x" || die "could not unpack $asset"
  [ -f "$tmp/x/gaiadesk-cli" ] || die "$asset has no gaiadesk-cli at its root"
  chmod 755 "$tmp/x/gaiadesk-cli"

  sudo=""
  if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
    if [ "$global" = 1 ] && [ "$(id -u)" != 0 ] && has sudo; then
      say "$dir needs administrator rights; using sudo"
      sudo="sudo"
      $sudo mkdir -p "$dir"
    else
      die "cannot write to $dir (set GAIADESK_INSTALL to another directory, or use --global)"
    fi
  fi

  # Copy next to the target, then rename over it: a running gaiadesk-cli
  # keeps its old file, and nothing is left half-written.
  $sudo cp "$tmp/x/gaiadesk-cli" "$dir/.gaiadesk-cli.new.$$"
  $sudo chmod 755 "$dir/.gaiadesk-cli.new.$$"
  $sudo mv -f "$dir/.gaiadesk-cli.new.$$" "$dir/gaiadesk-cli"
  $sudo ln -sf gaiadesk-cli "$dir/gaiadesk"

  installed=$("$dir/gaiadesk-cli" --version 2>/dev/null || true)
  say "installed ${installed:-gaiadesk-cli} to $dir/gaiadesk-cli (and $dir/gaiadesk)"
  path_hint "$dir"
  say "next: gaiadesk login, then gaiadesk devices (gaiadesk --help for everything)"
}

main "$@"
