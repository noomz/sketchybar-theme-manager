#!/usr/bin/env bash
# Shared test helpers for the stm test suite.
# Sourced by every tests/test_*.sh. Zero external dependencies.
#
# Each test file gets its own sandbox directory. HOME, XDG_CONFIG_HOME,
# SKETCHYBAR_CONFIG_DIR and friends are all redirected inside it so a buggy
# test can never touch the real ~/.config/sketchybar.

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FIXTURES_DIR="$TESTS_DIR/fixtures"

# The bash used to *run* stm. CI overrides this to test 3.2 and 5.x.
STM_BASH=${STM_BASH:-/bin/bash}
STM_BIN="$REPO_ROOT/bin/stm"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

_tests_run=0
_tests_failed=0
_current_test=""

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

SANDBOX=""

setup_sandbox() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/stm-test.XXXXXX") || {
    echo "FATAL: could not create sandbox" >&2
    exit 99
  }

  # Redirect every path stm might read so the real config is untouchable.
  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$SANDBOX/home/.config"
  export XDG_STATE_HOME="$SANDBOX/home/.local/state"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"

  unset SKETCHYBAR_CONFIG_DIR STM_CONFIG STM_PALETTE_DIR STM_FORMAT STM_REGISTRY 2>/dev/null || true

  # Bundled palettes still come from the repo.
  export STM_ROOT="$REPO_ROOT"

  # Deterministic, colourless output.
  export NO_COLOR=1
  export TERM=dumb

  # Guard: refuse to continue if HOME did not actually move.
  case "$HOME" in
    "$SANDBOX"/*) : ;;
    *)
      echo "FATAL: sandbox HOME guard failed (HOME=$HOME)" >&2
      exit 99
      ;;
  esac

  # Put a stub `sketchybar` first on PATH so `--reload` never hits the real bar.
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/sketchybar" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STM_TEST_RELOAD_LOG"
exit 0
STUB
  chmod 755 "$SANDBOX/bin/sketchybar"
  export STM_TEST_RELOAD_LOG="$SANDBOX/reload.log"
  : >"$STM_TEST_RELOAD_LOG"

  # Default fetch stub: never opens the network. Serves fixtures / bundled
  # palettes by URL basename. STM_FETCH_EXIT / STM_FETCH_FILE override it.
  export STM_FETCH_LOG="$SANDBOX/fetch.log"
  : >"$STM_FETCH_LOG"
  cat >"$SANDBOX/bin/stm-fetch" <<'STUB'
#!/bin/sh
url=$1
dest=$2
printf '%s\t%s\n' "$url" "$dest" >> "${STM_FETCH_LOG:-/dev/null}"
if [ -n "${STM_FETCH_EXIT:-}" ]; then
  exit "$STM_FETCH_EXIT"
fi
if [ -n "${STM_FETCH_FILE:-}" ]; then
  if [ ! -f "$STM_FETCH_FILE" ]; then
    exit 22
  fi
  cp "$STM_FETCH_FILE" "$dest"
  exit 0
fi
base=$url
base=${base%%\?*}
base=${base%%#*}
base=${base##*/}
src=""
if [ -n "${STM_TEST_FIXTURES:-}" ] && [ -f "$STM_TEST_FIXTURES/bad/$base" ]; then
  src="$STM_TEST_FIXTURES/bad/$base"
elif [ -n "${STM_TEST_FIXTURES:-}" ] && [ -f "$STM_TEST_FIXTURES/$base" ]; then
  src="$STM_TEST_FIXTURES/$base"
elif [ -n "${STM_TEST_REPO:-}" ] && [ -f "$STM_TEST_REPO/palettes/$base" ]; then
  src="$STM_TEST_REPO/palettes/$base"
else
  exit 22
fi
cp "$src" "$dest"
exit 0
STUB
  chmod 755 "$SANDBOX/bin/stm-fetch"
  export STM_FETCH="$SANDBOX/bin/stm-fetch"
  export STM_TEST_FIXTURES="$FIXTURES_DIR"
  export STM_TEST_REPO="$REPO_ROOT"
  unset STM_FETCH_EXIT STM_FETCH_FILE 2>/dev/null || true

  # Default POST stub: never opens the network. Logs to STM_POST_LOG.
  export STM_POST_LOG="$SANDBOX/post.log"
  : >"$STM_POST_LOG"
  cat >"$SANDBOX/bin/stm-post" <<'STUB'
#!/bin/sh
url=$1
body=$2
payload=""
if [ -n "$body" ] && [ -f "$body" ]; then
  payload=$(tr -d '\n' <"$body")
fi
printf 'POST\t%s\t%s\n' "$url" "$payload" >> "${STM_POST_LOG:-/dev/null}"
if [ -n "${STM_POST_EXIT:-}" ]; then
  exit "$STM_POST_EXIT"
fi
exit 0
STUB
  chmod 755 "$SANDBOX/bin/stm-post"
  export STM_POST="$SANDBOX/bin/stm-post"
  unset STM_POST_EXIT 2>/dev/null || true
  export PATH="$SANDBOX/bin:$PATH"
}

teardown_sandbox() {
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    case "$SANDBOX" in
      /tmp/stm-test.*|/var/folders/*/stm-test.*|"${TMPDIR%/}"/stm-test.*)
        rm -rf "$SANDBOX"
        ;;
      *)
        echo "WARN: refusing to remove suspicious sandbox path: $SANDBOX" >&2
        ;;
    esac
  fi
  SANDBOX=""
}

# reload_count -> number of times the sketchybar stub was invoked
reload_count() {
  if [ -f "$STM_TEST_RELOAD_LOG" ]; then
    # shellcheck disable=SC2002
    cat "$STM_TEST_RELOAD_LOG" | wc -l | tr -d ' '
  else
    echo 0
  fi
}

reset_reload_log() {
  : >"$STM_TEST_RELOAD_LOG"
}

# ---------------------------------------------------------------------------
# Running stm
# ---------------------------------------------------------------------------

# Captured from the last run_stm call.
STM_OUT=""
STM_ERR=""
STM_STATUS=0

# run_stm <args...> — never fails the script; inspect STM_STATUS.
run_stm() {
  local out_file err_file
  out_file="$SANDBOX/.stdout.$$"
  err_file="$SANDBOX/.stderr.$$"

  set +e
  "$STM_BASH" "$STM_BIN" "$@" >"$out_file" 2>"$err_file"
  STM_STATUS=$?
  set -e
  set +e # keep tests tolerant

  STM_OUT=$(cat "$out_file")
  STM_ERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
  return 0
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

_fail() {
  _tests_failed=$((_tests_failed + 1))
  printf 'not ok %d - %s\n' "$_tests_run" "$_current_test"
  printf '#   %s\n' "$1"
  shift
  while [ "$#" -gt 0 ]; do
    printf '#   %s\n' "$1"
    shift
  done
}

_pass() {
  printf 'ok %d - %s\n' "$_tests_run" "$_current_test"
}

# it <name> — start a new assertion group. Call before the asserts.
it() {
  _tests_run=$((_tests_run + 1))
  _current_test="$1"
  _current_failed=0
}

# done_it — close the group, emitting ok/not ok exactly once.
done_it() {
  if [ "${_current_failed:-0}" -eq 0 ]; then
    _pass
  fi
  _current_failed=0
}

_note_fail() {
  if [ "${_current_failed:-0}" -eq 0 ]; then
    _current_failed=1
    _fail "$@"
  else
    while [ "$#" -gt 0 ]; do
      printf '#   %s\n' "$1"
      shift
    done
  fi
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-values differ}"
  if [ "$expected" != "$actual" ]; then
    _note_fail "$msg" "expected: [$expected]" "actual:   [$actual]"
  fi
}

assert_ne() {
  local unexpected="$1" actual="$2" msg="${3:-values should differ}"
  if [ "$unexpected" = "$actual" ]; then
    _note_fail "$msg" "both were: [$actual]"
  fi
}

assert_status() {
  local expected="$1" msg="${2:-exit status}"
  if [ "$expected" != "$STM_STATUS" ]; then
    _note_fail "$msg" "expected status: $expected" "actual status:   $STM_STATUS" \
      "stdout: $STM_OUT" "stderr: $STM_ERR"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-substring not found}"
  case "$haystack" in
    *"$needle"*) : ;;
    *) _note_fail "$msg" "needle: [$needle]" "haystack: [$haystack]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-substring unexpectedly found}"
  case "$haystack" in
    *"$needle"*) _note_fail "$msg" "needle: [$needle]" "haystack: [$haystack]" ;;
    *) : ;;
  esac
}

assert_file_exists() {
  local path="$1" msg="${2:-file should exist}"
  if [ ! -f "$path" ]; then
    _note_fail "$msg" "path: $path"
  fi
}

assert_file_absent() {
  local path="$1" msg="${2:-file should not exist}"
  if [ -e "$path" ]; then
    _note_fail "$msg" "path: $path"
  fi
}

assert_file_contains() {
  local path="$1" needle="$2" msg="${3:-file content}"
  if [ ! -f "$path" ]; then
    _note_fail "$msg" "file missing: $path"
    return
  fi
  if ! grep -qF -- "$needle" "$path"; then
    _note_fail "$msg" "needle: [$needle]" "file: $path"
  fi
}

assert_file_not_contains() {
  local path="$1" needle="$2" msg="${3:-file content}"
  if [ ! -f "$path" ]; then
    _note_fail "$msg" "file missing: $path"
    return
  fi
  if grep -qF -- "$needle" "$path"; then
    _note_fail "$msg" "unexpected needle: [$needle]" "file: $path"
  fi
}

assert_files_equal() {
  local a="$1" b="$2" msg="${3:-files should be identical}"
  if ! cmp -s "$a" "$b"; then
    _note_fail "$msg" "a: $a" "b: $b"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# make_lua_config <dir> — SbarLua-style config with a colors.lua that falls back
# to colors_generated.lua when present.
make_lua_config() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$FIXTURES_DIR/lua-config/colors.lua" "$dir/colors.lua"
  cp "$FIXTURES_DIR/lua-config/init.lua" "$dir/init.lua"
}

# make_plain_lua_config <dir> — SbarLua colors.lua with no colors_generated hook.
make_plain_lua_config() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$FIXTURES_DIR/lua-plain/colors.lua" "$dir/colors.lua"
  cp "$FIXTURES_DIR/lua-plain/init.lua" "$dir/init.lua"
}

# make_bash_config <dir>
make_bash_config() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$FIXTURES_DIR/bash-config/colors.sh" "$dir/colors.sh"
  cp "$FIXTURES_DIR/bash-config/sketchybarrc" "$dir/sketchybarrc"
}

# make_both_config <dir> — ambiguous: lua and bash signals both present.
make_both_config() {
  local dir="$1"
  make_lua_config "$dir"
  make_bash_config "$dir"
}

# ---------------------------------------------------------------------------
# Suite lifecycle
# ---------------------------------------------------------------------------

finish() {
  teardown_sandbox
  if [ "$_tests_failed" -gt 0 ]; then
    printf '# %s: %d/%d failed\n' "$(basename "$0")" "$_tests_failed" "$_tests_run"
    exit 1
  fi
  printf '# %s: %d/%d passed\n' "$(basename "$0")" "$_tests_run" "$_tests_run"
  exit 0
}

trap 'teardown_sandbox' EXIT INT TERM
