#!/usr/bin/env bash
# Packaging (#16): install.sh ships the bundled item bundles to
# share/stm/bundles/items, known files only, and the installed stm finds them
# relative to its symlink-resolved location (C3, V21). The Homebrew formula
# installs the same layout into its Cellar.
#
# A fake `curl` serves a release tarball built in the sandbox, so the
# installer never touches the network.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

REL="$SANDBOX/rel/stm-main"
TARBALL="$SANDBOX/stm.tar.gz"
P="$SANDBOX/prefix"
ITEMS="$P/share/stm/bundles/items"

mkdir -p "$SANDBOX/fakebin"
cat >"$SANDBOX/fakebin/curl" <<'EOF'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "$STM_TEST_TARBALL" "$out"
EOF
chmod 755 "$SANDBOX/fakebin/curl"

# make_release — a release tree like the GitHub archive of this repo.
make_release() {
  rm -rf "$SANDBOX/rel"
  mkdir -p "$REL/bin" "$REL/palettes" "$REL/bundles/items"
  cp "$REPO_ROOT/bin/stm" "$REL/bin/stm"
  cp "$REPO_ROOT"/palettes/*.toml "$REL/palettes/"
  cp -R "$REPO_ROOT"/bundles/items/* "$REL/bundles/items/"
}

# pack_release — tar the release tree as the GitHub archive would.
pack_release() {
  rm -f "$TARBALL"
  tar -czf "$TARBALL" -C "$SANDBOX/rel" stm-main
}

# run_installer — run install.sh against the packed release into $P.
run_installer() {
  STM_PREFIX="$P" STM_ALLOW_ANY_OS=1 STM_TEST_TARBALL="$TARBALL" \
    PATH="$SANDBOX/fakebin:$PATH" sh "$REPO_ROOT/install.sh" \
    >"$SANDBOX/install.out" 2>"$SANDBOX/install.err"
  INSTALL_STATUS=$?
}

# installed_items — every path under the installed item dir, sorted.
installed_items() {
  (cd -- "$ITEMS" && find . | LC_ALL=C sort)
}

# The installed tree of the bundles this repo ships.
SHIPPED=(. ./ai ./ai/item.lua ./ai/item.toml ./ai/plugin.sh
  ./battery ./battery/item.lua ./battery/item.toml ./battery/plugin.sh
  ./clock ./clock/item.lua ./clock/item.toml
  ./cpu ./cpu/item.lua ./cpu/item.toml ./cpu/plugin.sh
  ./date ./date/item.lua ./date/item.toml
  ./disk ./disk/item.lua ./disk/item.toml ./disk/plugin.sh
  ./mem ./mem/item.lua ./mem/item.toml ./mem/plugin.sh
  ./net ./net/item.lua ./net/item.toml ./net/plugin.sh
  ./netspeed ./netspeed/item.lua ./netspeed/item.toml ./netspeed/plugin.sh
  ./spotify ./spotify/item.lua ./spotify/item.toml ./spotify/plugin.sh
  ./tailscale ./tailscale/item.lua ./tailscale/item.toml ./tailscale/plugin.sh)

# shipped [path...] — that tree plus the given paths, sorted like installed_items.
shipped() {
  printf '%s\n' "${SHIPPED[@]}" "$@" | LC_ALL=C sort
}

it "install.sh ships bundled items, known files only (C3)"
make_release
printf 'not item code\n' >"$REL/bundles/items/tailscale/README.md"
mkdir -p "$REL/bundles/items/tailscale/extra"
printf 'x\n' >"$REL/bundles/items/tailscale/extra/x.lua"
mkdir -p "$REL/bundles/items/linky"
cp "$REPO_ROOT/bundles/items/tailscale/item.toml" "$REL/bundles/items/linky/item.toml"
ln -s /etc/hosts "$REL/bundles/items/linky/item.lua"
mkdir -p "$REL/bundles/items/Bad.Name"
cp "$REPO_ROOT"/bundles/items/tailscale/* "$REL/bundles/items/Bad.Name/"
ln -s tailscale "$REL/bundles/items/alias"
pack_release
run_installer
assert_eq 0 "$INSTALL_STATUS" "install.sh must succeed: $(cat "$SANDBOX/install.err")"
assert_file_exists "$P/bin/stm"
assert_eq "$(shipped ./linky ./linky/item.toml)" \
  "$(installed_items)" "only item.toml, item.lua and plugin.sh from validly named, real bundle dirs"
for f in ai/plugin.sh battery/plugin.sh cpu/plugin.sh disk/plugin.sh mem/plugin.sh net/plugin.sh netspeed/plugin.sh spotify/plugin.sh tailscale/plugin.sh; do
  assert_files_equal "$REPO_ROOT/bundles/items/$f" "$ITEMS/$f"
done
for b in ai battery clock cpu date disk mem net netspeed spotify tailscale; do
  for f in item.toml item.lua; do
    assert_files_equal "$REPO_ROOT/bundles/items/$b/$f" "$ITEMS/$b/$f"
  done
done
done_it

it "installed stm finds its items through a symlink, without STM_ROOT (V21)"
mkdir -p "$SANDBOX/linkbin"
ln -s "$P/bin/stm" "$SANDBOX/linkbin/stm"
STM_ROOT="" STM_BIN="$SANDBOX/linkbin/stm" run_stm --porcelain lint item:tailscale
assert_status 0
assert_eq "ok	item:tailscale" "$STM_OUT"
STM_ROOT="" STM_BIN="$P/bin/stm" run_stm --porcelain lint item:tailscale
assert_status 0
done_it

it "reinstall drops files and bundles the release no longer ships"
make_release
pack_release
printf 'stale\n' >"$ITEMS/tailscale/old.lua"
run_installer
assert_eq 0 "$INSTALL_STATUS" "install.sh must succeed: $(cat "$SANDBOX/install.err")"
assert_eq "$(shipped)" "$(installed_items)"
assert_eq "" "$(find "$P/share/stm/bundles" -name '.items.*')" "no staging dir left behind"
done_it

it "a release without bundles/items still installs"
make_release
rm -rf "$REL/bundles"
pack_release
rm -rf "$P"
run_installer
assert_eq 0 "$INSTALL_STATUS" "install.sh must succeed: $(cat "$SANDBOX/install.err")"
assert_file_exists "$P/bin/stm"
assert_file_absent "$ITEMS"
done_it

finish
