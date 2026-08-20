#!/usr/bin/env bash
#
# stm search + install <slug> via the portal catalog (#9).
# Registry JSON is stubbed; palette bytes come from the author source_url.
# Never hits the live network.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_lua_config "$D"
USER_PAL="$D/palettes"
REG="https://portal.test"
AUTHOR="https://raw.githubusercontent.com/alice/themes/main/dracula.toml"
DECOY="https://raw.githubusercontent.com/alice/themes/main/decoy.toml"

copy_slug() {
  local dest="$1" slug="$2"
  sed "s/^slug = .*/slug = \"$slug\"/;s/^name = .*/name = \"$slug\"/;s/^variant_label = .*/variant_label = \"$slug\"/" \
    "$REPO_ROOT/palettes/nord.toml" >"$dest"
}

reset_logs() {
  : >"$STM_FETCH_LOG"
  : >"$STM_POST_LOG"
}

fetch_log() {
  cat "$STM_FETCH_LOG" 2>/dev/null || true
}

post_log() {
  cat "$STM_POST_LOG" 2>/dev/null || true
}

copy_slug "$SANDBOX/dracula.toml" dracula
copy_slug "$SANDBOX/decoy.toml" decoy
# Unique byte so dest-equality checks cannot pass on the wrong file.
printf '\n# author-payload\n' >>"$SANDBOX/dracula.toml"
printf '\n# portal-must-not-write-this\n' >>"$SANDBOX/decoy.toml"

mkdir -p "$SANDBOX/portal"
cat >"$SANDBOX/portal/dracula.json" <<EOF
{"slug":"dracula","name":"Dracula","source_url":"$AUTHOR","ref":"main","sha256":"abc","broken":false}
EOF
cat >"$SANDBOX/portal/broken.json" <<EOF
{"slug":"broken-theme","name":"Broken","source_url":"$AUTHOR","ref":"main","sha256":"abc","broken":true}
EOF
cat >"$SANDBOX/portal/list.json" <<EOF
[{"slug":"dracula","name":"Dracula","author":"alice","source_url":"$AUTHOR","rating":4.5,"installs":12},{"slug":"nord","name":"Nord","author":"bob","source_url":"https://raw.githubusercontent.com/bob/themes/main/nord.toml","rating":0,"installs":3}]
EOF
cat >"$SANDBOX/portal/search-dracula.json" <<EOF
[{"slug":"dracula","name":"Dracula","author":"alice","source_url":"$AUTHOR","rating":4.5,"installs":12}]
EOF
printf '%s\n' '[]' >"$SANDBOX/portal/empty.json"

# Palette bytes served from the catalog itself — must never be the install dest.
cp "$SANDBOX/decoy.toml" "$SANDBOX/portal/hostile.toml"

cat >"$SANDBOX/bin/portal-fetch" <<'STUB'
#!/bin/sh
url=$1
dest=$2
printf '%s\t%s\n' "$url" "$dest" >> "${STM_FETCH_LOG:-/dev/null}"
if [ -n "${STM_FETCH_EXIT:-}" ]; then
  exit "$STM_FETCH_EXIT"
fi
case "$url" in
  https://portal.test/v1/themes/dracula)
    cp "$STM_PORTAL_DIR/dracula.json" "$dest"
    exit 0
    ;;
  https://portal.test/v1/themes/broken-theme)
    cp "$STM_PORTAL_DIR/broken.json" "$dest"
    exit 0
    ;;
  https://portal.test/v1/themes/hostile)
    cp "$STM_PORTAL_DIR/hostile.toml" "$dest"
    exit 0
    ;;
  https://portal.test/v1/themes/missing)
    exit 22
    ;;
  https://portal.test/v1/themes)
    cp "$STM_PORTAL_DIR/empty.json" "$dest"
    exit 0
    ;;
  https://portal.test/v1/themes\?q= | https://portal.test/v1/themes?q=)
    cp "$STM_PORTAL_DIR/list.json" "$dest"
    exit 0
    ;;
  https://portal.test/v1/themes?q=dracula)
    cp "$STM_PORTAL_DIR/search-dracula.json" "$dest"
    exit 0
    ;;
  https://from-flag.test/v1/themes?q=dracula)
    cp "$STM_PORTAL_DIR/search-dracula.json" "$dest"
    exit 0
    ;;
  https://from-env.test/v1/themes?q=dracula)
    cp "$STM_PORTAL_DIR/search-dracula.json" "$dest"
    exit 0
    ;;
  https://from-config.test/v1/themes?q=dracula)
    cp "$STM_PORTAL_DIR/search-dracula.json" "$dest"
    exit 0
    ;;
  https://raw.githubusercontent.com/alice/themes/main/dracula.toml)
    cp "$STM_AUTHOR_FILE" "$dest"
    exit 0
    ;;
  https://raw.githubusercontent.com/alice/themes/main/decoy.toml)
    cp "$STM_DECOY_FILE" "$dest"
    exit 0
    ;;
  https://raw.githubusercontent.com/alice/themes/HEAD/palettes/nord.toml | \
  https://raw.githubusercontent.com/alice/themes/HEAD/nord.toml)
    cp "$STM_TEST_REPO/palettes/nord.toml" "$dest"
    exit 0
    ;;
  https://raw.githubusercontent.com/alice/themes/main/shebang.toml | \
  https://raw.githubusercontent.com/alice/themes/HEAD/palettes/shebang.toml)
    cp "$STM_TEST_FIXTURES/bad/shebang.toml" "$dest"
    exit 0
    ;;
esac
exit 22
STUB
chmod 755 "$SANDBOX/bin/portal-fetch"
export STM_FETCH="$SANDBOX/bin/portal-fetch"
export STM_PORTAL_DIR="$SANDBOX/portal"
export STM_AUTHOR_FILE="$SANDBOX/dracula.toml"
export STM_DECOY_FILE="$SANDBOX/decoy.toml"

NORD_RAW="https://raw.githubusercontent.com/alice/themes/HEAD/palettes/nord.toml"
cat >"$SANDBOX/portal/publish.json" <<EOF
{"slug":"nord","name":"Nord","source_url":"$NORD_RAW","ref":"HEAD","sha256":"abc","broken":false}
EOF
cat >"$SANDBOX/bin/portal-post" <<'STUB'
#!/bin/sh
url=$1
body=$2
payload=""
if [ -n "$body" ] && [ -f "$body" ]; then
  payload=$(tr -d '\n' <"$body")
fi
auth=""
[ -n "${STM_AUTH_BEARER:-}" ] && auth="bearer"
printf 'POST\t%s\t%s\t%s\n' "$url" "$payload" "$auth" >> "${STM_POST_LOG:-/dev/null}"
if [ -n "${STM_POST_EXIT:-}" ]; then
  exit "$STM_POST_EXIT"
fi
case "$url" in
  */v1/stats/install)
    exit 0
    ;;
  */v1/themes)
    case "$payload" in
      *'"source_url":""'*)
        printf '%s\n' '{"login":"alice"}'
        exit 0
        ;;
      *)
        if [ -n "${STM_POST_BODY:-}" ] && [ -f "${STM_POST_BODY}" ]; then
          cat "${STM_POST_BODY}"
        elif [ -n "${STM_PORTAL_DIR:-}" ] && [ -f "${STM_PORTAL_DIR}/publish.json" ]; then
          cat "${STM_PORTAL_DIR}/publish.json"
        fi
        exit 0
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod 755 "$SANDBOX/bin/portal-post"
export STM_POST="$SANDBOX/bin/portal-post"

CRED="${XDG_CONFIG_HOME}/stm/credentials"
TOKEN="test-token-alice"

cred_mode() {
  stat -f %Lp "$1"
}

# --- search ----------------------------------------------------------------

it "search dracula prints the catalog row and writes nothing"
reset_logs
run_stm --dir "$D" --registry "$REG" search dracula
assert_status 0
assert_contains "$STM_OUT" "dracula"
assert_contains "$STM_OUT" "Dracula"
assert_contains "$STM_OUT" "alice"
assert_contains "$STM_OUT" "4.5"
assert_contains "$STM_OUT" "12"
assert_file_absent "$USER_PAL/dracula.toml"
assert_file_absent "$D/colors_generated.lua"
assert_contains "$(fetch_log)" "https://portal.test/v1/themes?q=dracula"
assert_not_contains "$(fetch_log)" "$AUTHOR" "search must not GET source_url"
assert_eq "" "$(post_log)" "search must not POST stats"
done_it

it "search --porcelain is tab-separated slug name author rating installs"
reset_logs
run_stm --dir "$D" --registry "$REG" --porcelain search dracula
assert_status 0
assert_eq "dracula	Dracula	alice	4.5	12" "$STM_OUT"
done_it

it "search with an empty query lists a page of everything"
reset_logs
run_stm --dir "$D" --registry "$REG" search
assert_status 0
assert_contains "$STM_OUT" "dracula"
assert_contains "$STM_OUT" "nord"
assert_contains "$(fetch_log)" "https://portal.test/v1/themes?q="
assert_not_contains "$(fetch_log)" "$AUTHOR"
done_it

# --- install <slug> --------------------------------------------------------

it "install dracula uses source_url bytes, not the portal body"
reset_logs
run_stm --dir "$D" --registry "$REG" install dracula
assert_status 0
assert_file_exists "$USER_PAL/dracula.toml"
assert_files_equal "$SANDBOX/dracula.toml" "$USER_PAL/dracula.toml" \
  "dest must be the author palette, not catalog json"
assert_file_contains "$USER_PAL/dracula.toml" "author-payload"
assert_file_not_contains "$USER_PAL/dracula.toml" "portal-must-not-write-this"
assert_file_absent "$D/colors_generated.lua"
assert_contains "$(fetch_log)" "https://portal.test/v1/themes/dracula"
assert_contains "$(fetch_log)" "$AUTHOR"
assert_eq "1" "$(post_log | grep -c '/v1/stats/install' | tr -d ' ')"
assert_contains "$(post_log)" '"slug":"dracula"'
done_it

it "palette bytes from the portal itself are not written"
reset_logs
run_stm --dir "$D" --registry "$REG" install hostile
assert_ne 0 "$STM_STATUS"
assert_file_absent "$USER_PAL/hostile.toml"
assert_file_absent "$USER_PAL/decoy.toml"
assert_not_contains "$(fetch_log)" "$DECOY" "must not fall through to a decoy author url"
assert_eq "" "$(post_log)"
done_it

it "broken=true is not found, prints source_url, and does not fetch the palette"
reset_logs
run_stm --dir "$D" --registry "$REG" install broken-theme
assert_status 3
assert_contains "$STM_ERR" "$AUTHOR"
assert_file_absent "$USER_PAL/broken-theme.toml"
assert_contains "$(fetch_log)" "https://portal.test/v1/themes/broken-theme"
assert_not_contains "$(fetch_log)" "$AUTHOR" "broken listings must not GET source_url"
assert_eq "" "$(post_log)"
done_it

it "a missing catalog slug exits 3 and writes nothing"
reset_logs
run_stm --dir "$D" --registry "$REG" install missing
assert_status 3
assert_file_absent "$USER_PAL/missing.toml"
assert_eq "" "$(post_log)"
done_it

it "git-spec install does not POST stats"
reset_logs
run_stm --dir "$D" --registry "$REG" install alice/themes/palettes/nord.toml
assert_status 0
assert_file_exists "$USER_PAL/nord.toml"
assert_eq "" "$(post_log)" "direct spec install must not POST /v1/stats/install"
assert_not_contains "$(fetch_log)" "https://portal.test/"
done_it

it "stats POST failure still leaves dest and exit 0"
rm -f "$USER_PAL/dracula.toml"
reset_logs
export STM_POST_EXIT=7
run_stm --dir "$D" --registry "$REG" --force install dracula
assert_status 0
assert_file_exists "$USER_PAL/dracula.toml"
assert_files_equal "$SANDBOX/dracula.toml" "$USER_PAL/dracula.toml"
assert_contains "$(post_log)" "/v1/stats/install"
unset STM_POST_EXIT
done_it

it "apply and preview make zero fetch or registry calls"
reset_logs
run_stm --dir "$D" --registry "$REG" preview nord
assert_status 0
run_stm --dir "$D" --registry "$REG" --no-reload apply nord
assert_status 0
assert_eq "" "$(fetch_log)" "offline commands must not call STM_FETCH"
assert_eq "" "$(post_log)" "offline commands must not POST"
done_it

# --- registry override -----------------------------------------------------

it "--registry wins over STM_REGISTRY"
reset_logs
export STM_REGISTRY="https://from-env.test"
run_stm --dir "$D" --registry https://from-flag.test search dracula
assert_status 0
assert_contains "$(fetch_log)" "https://from-flag.test/v1/themes?q=dracula"
assert_not_contains "$(fetch_log)" "https://from-env.test/"
unset STM_REGISTRY
done_it

it "STM_REGISTRY is used when --registry is omitted"
reset_logs
export STM_REGISTRY="https://from-env.test"
run_stm --dir "$D" search dracula
assert_status 0
assert_contains "$(fetch_log)" "https://from-env.test/v1/themes?q=dracula"
unset STM_REGISTRY
done_it

it "registry = in stm.config.toml is used when flag and env are unset"
reset_logs
printf 'registry = "https://from-config.test"\n' >"$D/stm.config.toml"
run_stm --dir "$D" search dracula
assert_status 0
assert_contains "$(fetch_log)" "https://from-config.test/v1/themes?q=dracula"
rm -f "$D/stm.config.toml"
done_it

it "an http registry is refused before any fetch"
reset_logs
run_stm --dir "$D" --registry http://portal.test search dracula
assert_status 64
assert_eq "" "$(fetch_log)"
done_it

# --- login / logout / publish (#10) ----------------------------------------

it "login with STM_TOKEN writes credentials 0600 and hides the token"
reset_logs
export STM_TOKEN="$TOKEN"
run_stm --dir "$D" --registry "$REG" --verbose login
assert_status 0
assert_file_exists "$CRED"
assert_eq "600" "$(cred_mode "$CRED")"
assert_file_contains "$CRED" "registry=${REG}"
assert_file_contains "$CRED" "$TOKEN"
assert_contains "$STM_OUT" "alice"
assert_not_contains "$STM_OUT" "$TOKEN"
assert_not_contains "$STM_ERR" "$TOKEN"
assert_contains "$(post_log)" "/v1/themes"
assert_contains "$(post_log)" "bearer"
assert_contains "$(post_log)" '"source_url":""'
unset STM_TOKEN
done_it

it "logout removes the credentials file and is idempotent"
run_stm --dir "$D" --registry "$REG" logout
assert_status 0
assert_file_absent "$CRED"
run_stm --dir "$D" --registry "$REG" logout
assert_status 0
done_it

it "publish posts source_url only, never the palette body"
reset_logs
export STM_TOKEN="$TOKEN"
run_stm --dir "$D" --registry "$REG" login
unset STM_TOKEN
reset_logs
run_stm --dir "$D" --registry "$REG" --verbose publish alice/themes/palettes/nord.toml
assert_status 0
assert_contains "$(post_log)" "/v1/themes"
assert_contains "$(post_log)" '"source_url":"'"$NORD_RAW"'"'
assert_contains "$(post_log)" "bearer"
assert_not_contains "$(post_log)" "bar_bg"
assert_not_contains "$(post_log)" "[colors]"
assert_not_contains "$(post_log)" "0xff"
assert_not_contains "$STM_OUT" "$TOKEN"
assert_not_contains "$STM_ERR" "$TOKEN"
assert_contains "$STM_OUT" "nord"
done_it

it "publish of a hostile palette exits 1 and does not POST"
reset_logs
run_stm --dir "$D" --registry "$REG" publish alice/themes/palettes/shebang.toml
assert_status 1
assert_eq "" "$(post_log)"
done_it

it "publish without credentials exits 2 and does not POST"
run_stm --dir "$D" --registry "$REG" logout
reset_logs
run_stm --dir "$D" --registry "$REG" publish alice/themes/palettes/nord.toml
assert_status 2
assert_contains "$STM_ERR" "stm login"
assert_eq "" "$(post_log)"
done_it

it "token never lands in the ledger, an installed palette, or a snapshot"
export STM_TOKEN="$TOKEN"
run_stm --dir "$D" --registry "$REG" login
unset STM_TOKEN
run_stm --dir "$D" --registry "$REG" --force install alice/themes/palettes/nord.toml
assert_status 0
assert_file_not_contains "${XDG_CONFIG_HOME}/stm/installed" "$TOKEN"
assert_file_not_contains "$USER_PAL/nord.toml" "$TOKEN"
run_stm --dir "$D" backup --all cred-snap
assert_status 0
if grep -rF -- "$TOKEN" "$D/.stm-backups" >/dev/null 2>&1; then
  _note_fail "snapshot must not contain the catalog token"
fi
assert_file_exists "$CRED"
done_it

finish
