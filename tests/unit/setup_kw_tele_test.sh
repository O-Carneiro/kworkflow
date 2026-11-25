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
  mkdir -p "${TD}/home/.local/bin"
  printf '%s\n' 'old kw_tele binary' > "${TD}/home/.local/bin/kw_tele"
  chmod 755 "${TD}/home/.local/bin/kw_tele"
}

function tearDown()
{
  cd "$ORIG_PWD" || return
  rm -rf "$TD"
}

# @curl_body: body of the fake curl; ${out} is the file given to --output (the
# fake refuses relative paths and paths inside the repo).
# 'return 22' is what --fail gives on a 404.
# Runs install_home with everything but clean_legacy, install_kw_tele and
# install_home faked.
function run_install_home()
{
  local curl_body="$1"
  local entry="${2:-install_home}"
  local driver="${TD}/driver.sh"
  local fn

  {
    printf '%s\n' '#!/usr/bin/env bash' \
      "export HOME='${TD}/home'" \
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
      'KW_TELE_PATH=""' \
      'SKIPCHECKS=1' \
      'function say() { printf "%s\n" "$*"; }' \
      'function warning() { printf "WARNING: %s\n" "$*"; }' \
      'function complain() { printf "ERROR: %s\n" "$*"; }' \
      "function curl() { local out=''; while [[ \$# -gt 0 ]]; do [[ \$1 == --output ]] && out=\$2; shift; done; [[ \$out == /* && \$out != ${ORIG_PWD}/* ]] || return 99; ${curl_body}; }" \
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

function test_failed_download_keeps_the_installed_kw_tele()
{
  run_install_home 'return 22'
  assertTrue "($LINENO) kw_tele still installed" "[[ -x ${TD}/home/.local/bin/kw_tele ]]"
  assertEquals "($LINENO) content untouched" 'old kw_tele binary' "$(< "${TD}/home/.local/bin/kw_tele")"
}

function test_failed_download_prints_a_warning()
{
  run_install_home 'return 22'
  assertContains "($LINENO)" "$(< "${TD}/out")" 'WARNING: -> Could not install `kw_tele`.'
}

# Control: the fixture really reaches install_kw_tele, and a good download
# replaces the binary.
function test_successful_download_installs_the_new_kw_tele()
{
  run_install_home 'printf "%s\n" "new kw_tele binary" > "$out"'
  assertEquals "($LINENO)" 'new kw_tele binary' "$(< "${TD}/home/.local/bin/kw_tele")"
}

# `kw --uninstall` goes through clean_legacy without the keep flag.
function test_uninstall_removes_kw_tele()
{
  run_install_home 'return 22' 'clean_legacy'
  assertFalse "($LINENO) kw_tele removed" "[[ -e ${TD}/home/.local/bin/kw_tele ]]"
}

function test_completely_remove_removes_kw_tele()
{
  run_install_home 'return 22' "clean_legacy '-d'"
  assertFalse "($LINENO) kw_tele removed" "[[ -e ${TD}/home/.local/bin/kw_tele ]]"
}

invoke_shunit
