#!/usr/bin/env bash

# setup.sh runs its argument parsing when sourced, so the functions under test
# are extracted with sed and run in a driver script under a temporary HOME.

include './tests/unit/utils.sh'

function oneTimeSetUp()
{
  declare -g ORIG_PWD="$PWD"
}

function setUp()
{
  TD="$(mktemp -d "${SHUNIT_TMPDIR}/setup.XXXXXX")"
  mkdir -p "${TD}/home/.local/bin" "${TD}/tmp"
  printf '%s\n' 'old kw_tele binary' > "${TD}/home/.local/bin/kw_tele"
  chmod 755 "${TD}/home/.local/bin/kw_tele"
}

function tearDown()
{
  cd "$ORIG_PWD" || return
  rm -rf "$TD"
}

# @curl_body: body of the fake curl; ${out} is the file given to --output (the
# fake refuses relative paths and paths inside the repo). Every argument it
# receives is recorded, one per line, in ${TD}/curl.args.
# 'return 22' is what --fail gives on a 404.
# @entry: function to run (default install_home)
# @kw_tele_path: value of KW_TELE_PATH (default empty: download)
# Runs install_home with everything but clean_legacy, install_kw_tele and
# install_home faked. mktemp works under ${TD}/tmp, so a leaked download shows
# (clean_legacy leaves its own trash dir there, so the dir itself is not checked).
function run_install_home()
{
  local curl_body="$1"
  local entry="${2:-install_home}"
  local kw_tele_path="${3:-}"
  local driver="${TD}/driver.sh"
  local fn

  {
    printf '%s\n' '#!/usr/bin/env bash' \
      "export HOME='${TD}/home' TMPDIR='${TD}/tmp'" \
      'unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME' \
      "declare -r app_name='kw'" \
      'declare -r kwbinpath="$HOME/.local/bin/$app_name"' \
      'declare -r binpath="$HOME/.local/bin"' \
      'declare -r libdir="$HOME/.local/lib/$app_name"' \
      'declare -r datadir="$HOME/.local/share/$app_name"' \
      'declare -r docdir="${datadir}/doc"' \
      'declare -r mandir="${datadir}/man"' \
      'declare -r sounddir="${datadir}/sound"' \
      'declare -r etcdir="$HOME/.config/$app_name"' \
      "declare -r KW_TELE_LATEST_RELEASE='http://release.test/kw_tele'" \
      "KW_TELE_PATH='${kw_tele_path}'" \
      'SKIPCHECKS=1' \
      'function say() { printf "%s\n" "$*"; }' \
      'function warning() { printf "WARNING: %s\n" "$*"; }' \
      'function complain() { printf "ERROR: %s\n" "$*"; }' \
      "function curl() { printf '%s\\n' \"\$@\" > '${TD}/curl.args'; local out=''; while [[ \$# -gt 0 ]]; do [[ \$1 == --output ]] && out=\$2; shift; done; [[ \$out == /* && \$out != ${ORIG_PWD}/* ]] || return 99; ${curl_body}; }" \
      'function rsync() { return 0; }' \
      'function check_dependencies() { :; }' \
      'function legacy_folders() { :; }' \
      'function synchronize_files() { :; }' \
      'function remove_legacy_git_from_kernel_config_manager() { :; }' \
      'function update_version() { :; }' \
      'function setup_bashrc_to_show_current_kw_env() { :; }' \
      'function install_patch_hub() { :; }' \
      'function remove_kw_from_PATH_variable() { :; }'
    for fn in clean_legacy install_kw_tele install_home; do
      sed -n "/^function ${fn}()/,/^}/p" "${ORIG_PWD}/setup.sh"
    done
    printf '%s\n' "$entry"
  } > "$driver"
  bash "$driver" > "${TD}/out" 2>&1 < /dev/null
}

# A failed download must leave the installed binary alone, whatever the failed
# curl left behind, and must not leak its temp dir.
function test_failed_download_keeps_the_installed_kw_tele_and_warns()
{
  local label
  local curl_body

  # label | fake curl body. The second one leaves an error page where curl was
  # told to write and exits 22, as a curl that does not clean up after --fail.
  while IFS='|' read -r label curl_body; do
    printf '%s\n' 'old kw_tele binary' > "${TD}/home/.local/bin/kw_tele"
    run_install_home "$curl_body"
    assertTrue "(${label}) kw_tele still installed" "[[ -x ${TD}/home/.local/bin/kw_tele ]]"
    assertEquals "(${label}) content untouched" 'old kw_tele binary' "$(< "${TD}/home/.local/bin/kw_tele")"
    assertContains "(${label})" "$(< "${TD}/out")" 'WARNING: -> Could not install `kw_tele`.'
    assertEquals "(${label}) download removed from the temp dir" '' "$(find "${TD}/tmp" -name kw_tele)"
  done << 'EOF'
404|return 22
error page written before the failure|printf "%s\n" "<html>Not Found</html>" > "$out"; return 22
EOF
}

# `kw --uninstall` goes through clean_legacy without the keep flag.
function test_uninstall_removes_kw_tele()
{
  run_install_home 'return 22' 'clean_legacy'
  assertFalse "($LINENO) --uninstall" "[[ -e ${TD}/home/.local/bin/kw_tele ]]"
}

# Control: the fixture really reaches install_kw_tele, and a good download
# replaces the binary.
function test_successful_download_installs_the_new_kw_tele()
{
  run_install_home 'printf "%s\n" "new kw_tele binary" > "$out"'
  assertEquals "($LINENO)" 'new kw_tele binary' "$(< "${TD}/home/.local/bin/kw_tele")"
}

# curl --fail is what turns an HTTP error page into a failure instead of a
# file that gets installed as kw_tele.
function test_download_uses_fail_and_a_temp_dir()
{
  local args

  run_install_home 'printf "%s\n" "new kw_tele binary" > "$out"'
  args="$(< "${TD}/curl.args")"
  assertContains "($LINENO) curl must fail on HTTP errors" "$args" '--fail'
  assertContains "($LINENO) release URL" "$args" 'http://release.test/kw_tele'
  assertNotContains "($LINENO) not downloaded into the bin dir" "$args" "${TD}/home/.local/bin"
}

function test_downloaded_kw_tele_is_installed_executable_and_the_temp_dir_removed()
{
  run_install_home 'printf "%s\n" "new kw_tele binary" > "$out"; chmod 644 "$out"'
  assertEquals "($LINENO) mode" 755 "$(stat --format=%a "${TD}/home/.local/bin/kw_tele")"
  assertEquals "($LINENO) download removed from the temp dir" '' "$(find "${TD}/tmp" -name kw_tele)"
}

# With KW_TELE_PATH the checkout's build.sh builds kw_tele in place and nothing
# is downloaded.
function test_kw_tele_path_builds_from_the_checkout()
{
  local label
  local build_body
  local binary
  local warned

  mkdir -p "${TD}/checkout"
  # label | build.sh body | kw_tele afterwards | warning shown
  while IFS='|' read -r label build_body binary warned; do
    printf '%s\n' 'old kw_tele binary' > "${TD}/home/.local/bin/kw_tele"
    rm -f "${TD}/curl.args" "${TD}/build.args"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$@\" > '${TD}/build.args'" "$build_body" > "${TD}/checkout/build.sh"
    chmod 755 "${TD}/checkout/build.sh"
    run_install_home 'return 99' install_home "${TD}/checkout"
    assertFalse "(${label}) nothing downloaded" "[[ -e ${TD}/curl.args ]]"
    assertEquals "(${label}) build.sh target" "${TD}/home/.local/bin/kw_tele" "$(< "${TD}/build.args")"
    assertEquals "(${label}) kw_tele afterwards" "$binary" "$(< "${TD}/home/.local/bin/kw_tele")"
    if [[ "$warned" == yes ]]; then
      assertContains "(${label}) warning" "$(< "${TD}/out")" 'WARNING: -> Could not install `kw_tele`.'
    else
      assertNotContains "(${label}) no warning" "$(< "${TD}/out")" 'Could not install `kw_tele`'
    fi
  done << 'EOF'
build succeeds|printf '%s\n' 'built kw_tele' > "$1"|built kw_tele|no
build fails|exit 7|old kw_tele binary|yes
EOF
}

invoke_shunit
