#!/bin/sh
#
# stm — SketchyBar Theme Manager · installer
#
#   curl -fsSL https://raw.githubusercontent.com/noomz/sketchybar-theme-manager/main/install.sh | sh
#
# Installs into your home directory. It never uses sudo, never writes outside
# the install prefix, and never edits your shell rc files.
#
# Environment:
#   STM_PREFIX        install prefix           (default: $HOME/.local)
#   STM_REF           git ref / tag to install (default: main)
#   STM_ALLOW_ANY_OS  set to 1 to skip the macOS check (for CI)
#
# Layout it creates:
#   $STM_PREFIX/bin/stm
#   $STM_PREFIX/share/stm/palettes/*.toml

set -eu

REPO="noomz/sketchybar-theme-manager"
PREFIX="${STM_PREFIX:-${HOME:-}/.local}"
REF="${STM_REF:-main}"

say() { printf '%s\n' "$*"; }
err() { printf 'install.sh: %s\n' "$*" >&2; }
die() {
  err "$*"
  exit 1
}

# --- preflight --------------------------------------------------------------

if [ -z "${HOME:-}" ]; then
  die "\$HOME is not set; refusing to guess an install location"
fi

if [ "${STM_ALLOW_ANY_OS:-0}" != "1" ]; then
  os=$(uname -s 2>/dev/null || echo unknown)
  if [ "$os" != "Darwin" ]; then
    die "SketchyBar is macOS-only (detected: $os). Set STM_ALLOW_ANY_OS=1 to override."
  fi
fi

for tool in curl tar mkdir cp chmod; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

case "$REF" in
  *[!A-Za-z0-9._/-]*) die "refusing to use an unusual STM_REF: $REF" ;;
esac

TARBALL="https://github.com/$REPO/archive/$REF.tar.gz"

say "stm installer"
say "  repo:   $REPO"
say "  ref:    $REF"
say "  prefix: $PREFIX"
say ""

# --- fetch ------------------------------------------------------------------

WORKDIR=""
cleanup() {
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/stm-install.XXXXXX") ||
  die "could not create a temporary directory"

say "Downloading $TARBALL"
if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$WORKDIR/stm.tar.gz" "$TARBALL"; then
  die "download failed (is the ref \"$REF\" valid?)"
fi

say "Extracting"
# --strip-components=1 drops the GitHub-generated "<repo>-<ref>/" wrapper. The
# extraction target is our own private temp dir, so a hostile archive cannot
# reach anything of yours; we then copy only the two paths we expect.
mkdir -p "$WORKDIR/src"
tar -xzf "$WORKDIR/stm.tar.gz" -C "$WORKDIR/src" --strip-components=1 ||
  die "could not extract the archive"

[ -f "$WORKDIR/src/bin/stm" ] || die "archive does not contain bin/stm"
[ -d "$WORKDIR/src/palettes" ] || die "archive does not contain palettes/"

# --- install ----------------------------------------------------------------

BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/stm/palettes"

say "Installing to $PREFIX"
mkdir -p "$BIN_DIR" "$SHARE_DIR"

cp "$WORKDIR/src/bin/stm" "$BIN_DIR/stm"
chmod 755 "$BIN_DIR/stm"

# Copy palettes individually so nothing unexpected in the archive comes along.
count=0
for f in "$WORKDIR/src/palettes"/*.toml; do
  [ -f "$f" ] || continue
  cp "$f" "$SHARE_DIR/"
  count=$((count + 1))
done
say "  installed $BIN_DIR/stm"
say "  installed $count palettes into $SHARE_DIR"

# --- verify -----------------------------------------------------------------

say ""
if ! "$BIN_DIR/stm" version; then
  die "the installed binary did not run"
fi

if ! "$BIN_DIR/stm" list --porcelain >/dev/null 2>&1; then
  err "warning: the installed stm could not read its palettes"
fi

# --- PATH hint --------------------------------------------------------------

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    say ""
    say "$BIN_DIR is not on your PATH. Add this to your shell profile:"
    say ""
    say "    export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

say ""
say "Done. Try:  stm list"
