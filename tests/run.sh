#!/usr/bin/env bash
# stm test runner — zero dependencies, no bats.
#
# Usage:
#   tests/run.sh                 # run every tests/test_*.sh
#   tests/run.sh test_toml.sh    # run selected files
#   STM_BASH=/opt/homebrew/bin/bash tests/run.sh   # run stm under bash 5.x
#
# Each test file is a standalone executable that sources helpers.sh and exits
# non-zero on failure.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)

STM_BASH=${STM_BASH:-/bin/bash}
export STM_BASH

if [ ! -x "$REPO_ROOT/bin/stm" ]; then
  echo "FATAL: $REPO_ROOT/bin/stm is missing or not executable" >&2
  exit 99
fi

if [ ! -x "$STM_BASH" ]; then
  echo "FATAL: STM_BASH=$STM_BASH is not executable" >&2
  exit 99
fi

files=""
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    case "$arg" in
      /*) files="$files $arg" ;;
      *) files="$files $TESTS_DIR/$arg" ;;
    esac
  done
else
  for f in "$TESTS_DIR"/test_*.sh; do
    [ -f "$f" ] || continue
    files="$files $f"
  done
fi

printf '# stm test suite\n'
printf '# repo:      %s\n' "$REPO_ROOT"
# shellcheck disable=SC2016  # $BASH_VERSION is evaluated by the inner shell, on purpose
printf '# stm bash:  %s (%s)\n' "$STM_BASH" "$("$STM_BASH" -c 'echo $BASH_VERSION')"
printf '# runner:    %s\n' "$BASH_VERSION"
printf '#\n'

total_files=0
failed_files=0
failed_names=""

for f in $files; do
  if [ ! -f "$f" ]; then
    printf '# SKIP missing %s\n' "$f"
    continue
  fi
  total_files=$((total_files + 1))
  name=$(basename "$f")
  printf '# --- %s ---\n' "$name"
  if "$BASH" "$f"; then
    :
  else
    failed_files=$((failed_files + 1))
    failed_names="$failed_names $name"
  fi
  printf '#\n'
done

printf '# =========================================\n'
if [ "$failed_files" -gt 0 ]; then
  printf '# FAILED: %d/%d test files\n' "$failed_files" "$total_files"
  printf '# failing:%s\n' "$failed_names"
  exit 1
fi
printf '# PASSED: %d/%d test files\n' "$total_files" "$total_files"
exit 0
