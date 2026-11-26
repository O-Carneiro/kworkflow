#!/usr/bin/env bash

include './src/build.sh' > /dev/null
include './src/deploy.sh' > /dev/null
include './tests/unit/utils.sh'
include './tests/unit/samples/telemetry/helpers.sh'
include './src/lib/telemetry.sh'

function oneTimeSetUp()
{
  declare -g ORIG_ETC_DIR="$KW_ETC_DIR"
  declare -g ORIG_XDG_DIRS="$XDG_CONFIG_DIRS"
  declare -g ORIG_PWD="$PWD"
  declare -g TEMPLATE="${PWD}/etc/init_templates/x86-64/build_template.config"

  parse_configuration "$KW_CONFIG_SAMPLE"
  parse_configuration "$KW_BUILD_CONFIG_SAMPLE" build_config
}

# Keep the real cmd_manager for the database calls; only `make` is faked. This
# must run before the override below is defined.
eval "$(declare -f cmd_manager | sed '1s/^cmd_manager/real_cmd_manager/')"

function cmd_manager()
{
  if [[ "$2" == make* ]]; then
    return "${FAKE_MAKE_RC:-0}"
  fi
  real_cmd_manager "$@"
}

function get_kernel_release_mock()
{
  printf '%s\n' '5.4.0-rc7-test'
}

function get_kernel_version_mock()
{
  printf '%s\n' '5.4.0'
}

function setUp()
{
  endSkipping
  tele_setup
  KW_ETC_DIR="$ORIG_ETC_DIR"
  XDG_CONFIG_DIRS="$ORIG_XDG_DIRS"
  KW_DATA_DIR="$TELE_DATA_DIR"
  KW_DB_DIR="${ORIG_PWD}/database"
  FAKE_MAKE_RC=0
  options_values=()
  configurations['disable_statistics_data_track']='no'

  cp "$TEMPLATE" "${TD}/build.config"
  FAKE_KERNEL="${TD}/fake_kernel"
  mkdir -p "$FAKE_KERNEL"
  mk_fake_kernel_root "$FAKE_KERNEL"
  cd "$FAKE_KERNEL" || fail "($LINENO) cannot enter the fake kernel"
}

function tearDown()
{
  cd "$ORIG_PWD" || return
  tele_teardown
}

# tele_make_db reads database/kwdb.sql relative to PWD, but tests run inside the fake kernel.
function make_db()
{
  (cd "$ORIG_PWD" && tele_make_db)
}

function write_fake_config()
{
  local path="$1"

  mkdir -p "${path%/*}"
  printf '%s\n' 'CONFIG_ZED=m' 'CONFIG_BTRFS_FS=y' 'CONFIG_AAA=m' '# CONFIG_OFF is not set' \
    'CONFIG_MID_X=m' 'CONFIG_STR="x=m"' > "$path"
}

function db_query()
{
  sqlite3 "$TELE_DB" "$1"
}

function run_build()
{
  (build_kernel_main 'SILENT') > "${TD}/build.out" 2> "${TD}/build.err" < /dev/null
}

function get_kernel_release()
{
  printf '%s\n' '5.4.0-rc7-test'
}

function get_kernel_version()
{
  printf '%s\n' '5.4.0'
}

# label|status|elapsed|count|names of the only row, joined across the shared tables
function stored_row()
{
  db_query "SELECT c.name || '|' || s.name || '|' || x.elapsed_time_in_secs || '|' || b.module_count || '|' || coalesce(b.module_names, '') FROM executed x JOIN command_label c ON c.id = x.command_label_id JOIN status s ON s.id = x.status_id JOIN build_modules b ON b.id = x.id"
}

# label|status of every executed row
function executed_rows()
{
  db_query "SELECT coalesce(group_concat(c.name || char(124) || s.name, ';'), '') FROM executed x JOIN command_label c ON c.id = x.command_label_id JOIN status s ON s.id = x.status_id"
}

function insert_report_row()
{
  sqlite3 -cmd 'PRAGMA foreign_keys = 1' "$TELE_DB" "INSERT INTO build_modules_report (label_name, status, date, time, elapsed_time_in_secs, module_count, module_names) VALUES ('build', 'success', '2026-01-02', '03:04:05', 7, 2, 'a,b');"
}

function drop_build_modules_objects()
{
  sqlite3 "$TELE_DB" 'DROP VIEW IF EXISTS build_modules_report; DROP TABLE IF EXISTS build_modules;'
}

# ------------------------------------------------------------------ schema

function test_schema_structure()
{
  make_db
  assertEquals "($LINENO) table" 'build_modules' "$(db_query "SELECT name FROM sqlite_master WHERE type='table' AND name='build_modules'")"
  assertEquals "($LINENO) view" 'build_modules_report' "$(db_query "SELECT name FROM sqlite_master WHERE type='view' AND name='build_modules_report'")"
  assertEquals "($LINENO) columns" 'id,module_count,module_names' \
    "$(db_query "SELECT group_concat(name) FROM pragma_table_info('build_modules')")"
  assertEquals "($LINENO) fk cascade" 'event|CASCADE' \
    "$(db_query "SELECT \"table\" || '|' || on_delete FROM pragma_foreign_key_list('build_modules')")"
}

# Inserting into the report view fans out to the shared tables, all under one event id.
function test_schema_insert_trigger_fills_every_table()
{
  make_db
  insert_report_row
  assertEquals "($LINENO) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) executed" 'build|success|7' \
    "$(db_query "SELECT c.name || '|' || s.name || '|' || x.elapsed_time_in_secs FROM executed x JOIN command_label c ON c.id = x.command_label_id JOIN status s ON s.id = x.status_id")"
  assertEquals "($LINENO) event date and time" '2026-01-02|03:04:05' "$(db_query "SELECT date || '|' || time FROM event")"
  assertEquals "($LINENO) build_modules" '2|a,b' "$(db_query "SELECT module_count || '|' || module_names FROM build_modules")"
  assertEquals "($LINENO) same id" '1' \
    "$(db_query 'SELECT count(*) FROM event e JOIN executed x ON x.id = e.id JOIN build_modules b ON b.id = e.id')"
  assertEquals "($LINENO) pending upload" '1' "$(db_query 'SELECT count(*) FROM event WHERE sent_at IS NULL')"
}

function test_schema_deleting_the_event_cascades()
{
  make_db
  insert_report_row
  sqlite3 -cmd 'PRAGMA foreign_keys = 1' "$TELE_DB" 'DELETE FROM executed; DELETE FROM event;'
  assertEquals "($LINENO) deleting the event cascades" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
}

function test_ensure_schema_adds_build_modules()
{
  make_db
  drop_build_modules_objects
  assertEquals "($LINENO) precondition" '0' "$(db_query "SELECT count(*) FROM sqlite_master WHERE name LIKE 'build_modules%'")"

  telemetry_paths
  telemetry_ensure_schema > /dev/null 2>&1
  assertEquals "($LINENO) status" 0 "$?"
  insert_report_row
  assertEquals "($LINENO) usable" '2|a,b' "$(db_query "SELECT module_count || '|' || module_names FROM build_modules")"

  telemetry_ensure_schema > "${TD}/o" 2> "${TD}/e"
  assertEquals "($LINENO) second run status" 0 "$?"
  assertEquals "($LINENO) silent" '' "$(< "${TD}/o")$(< "${TD}/e")"
  assertEquals "($LINENO) data kept" '1' "$(db_query 'SELECT count(*) FROM build_modules')"
}

# ------------------------------------------------------------------- build.sh

# build_modules_info prints the count on line 1 and the sorted names on line 2.
function test_build_modules_info()
{
  local label
  local count
  local names
  local config_lines
  local shown
  local -a config
  local -a lines

  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']=''
  rm -f "${FAKE_KERNEL}/.config"
  mapfile -t lines < <(build_modules_info)
  assertEquals "($LINENO) no config: count" '0' "${lines[0]}"
  assertEquals "($LINENO) no config: names" '' "${lines[1]:-}"

  # label | expected count | expected names | .config lines (separated by ';')
  while IFS='|' read -r label count names config_lines; do
    IFS=';' read -r -a config <<< "$config_lines"
    printf '%s\n' "${config[@]}" > "${FAKE_KERNEL}/.config"
    mapfile -t lines < <(build_modules_info)
    assertEquals "(${label}) count" "$count" "${lines[0]}"
    assertEquals "(${label}) names" "$names" "${lines[1]:-}"
    shown="$(build_info '' | grep 'Total modules')"
    assertEquals "(${label}) build_info agrees" "  Total modules to be compiled: ${count}" "$shown"
  done << 'EOF'
sorted|3|AAA,MID_X,ZED|CONFIG_ZED=m;CONFIG_BTRFS_FS=y;CONFIG_AAA=m;# CONFIG_OFF is not set;CONFIG_MID_X=m;CONFIG_STR="x=m"
non-module lines ignored|1|OK|# CONFIG_C=m;# CONFIG_X is not set;CONFIG_Y=y;CONFIG_Q="m";CONFIG_S="a=m";CONFIG_OK=m
empty config|0||
EOF
}

# The build clock: the first `date +%s` is the start, any later one is 3 s after
# it. Other date calls reach the real date.
function date()
{
  if [[ "$1" == '+%s' ]]; then
    if [[ -e "${TD}/clock.started" ]]; then
      printf '%s\n' $((FAKE_CLOCK_START + 3))
    else
      : > "${TD}/clock.started"
      printf '%s\n' "$FAKE_CLOCK_START"
    fi
    return 0
  fi
  command date "$@"
}

# The date, time and elapsed time of the row come from the build clock.
function test_build_success_records_the_modules_of_the_config()
{
  declare -g FAKE_CLOCK_START=1767323045
  rm -f "${TD}/clock.started"
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  run_build
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) build_modules" '3|AAA,MID_X,ZED' \
    "$(db_query "SELECT module_count || '|' || module_names FROM build_modules")"
  assertEquals "($LINENO) one build_modules row" '1' "$(db_query 'SELECT count(*) FROM build_modules')"
  assertEquals "($LINENO) executed row" 'build|success|3' \
    "$(db_query "SELECT c.name || '|' || s.name || '|' || x.elapsed_time_in_secs FROM executed x JOIN command_label c ON c.id = x.command_label_id JOIN status s ON s.id = x.status_id")"
  assertEquals "($LINENO) date and time of the start" "$(command date --date @1767323045 '+%Y-%m-%d|%H:%M:%S')" \
    "$(db_query "SELECT date || '|' || time FROM event")"
}

function test_build_without_a_config_records_zero_modules()
{
  make_db
  rm -f "${FAKE_KERNEL}/.config"
  run_build
  assertEquals "($LINENO) no config: row" '0|' "$(db_query "SELECT module_count || '|' || coalesce(module_names, '') FROM build_modules")"
}

# The failure keeps the modules of the .config the build used, on the same event id.
function test_build_failure_records_the_build_and_its_modules()
{
  declare -g FAKE_CLOCK_START=1767323045
  rm -f "${TD}/clock.started"
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  FAKE_MAKE_RC=2
  run_build
  assertEquals "($LINENO) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) executed" '1' "$(db_query 'SELECT count(*) FROM executed')"
  assertEquals "($LINENO) build_modules" '1' "$(db_query 'SELECT count(*) FROM build_modules')"
  assertEquals "($LINENO) stored row" 'build|failure|3|3|AAA,MID_X,ZED' "$(stored_row)"
  assertEquals "($LINENO) date and time of the start" "$(command date --date @1767323045 '+%Y-%m-%d|%H:%M:%S')" \
    "$(db_query "SELECT date || '|' || time FROM event")"
}

# Without the 4th and 5th arguments the call is the old successful build.
function test_build_modules_record_defaults_to_a_successful_build()
{
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  build_modules_record 1767323045 7 SILENT > /dev/null
  assertEquals "($LINENO) row" 'build|success|7|3|AAA,MID_X,ZED' "$(stored_row)"
}

# label : status : extra argument : expected stored row
function test_build_modules_record_label_and_status()
{
  local label
  local status
  local extra
  local expected

  while IFS=':' read -r label status extra expected; do
    make_db
    write_fake_config "${FAKE_KERNEL}/.config"
    build_modules_record 1767323045 7 SILENT "$label" "$status" ${extra:+"$extra"} > /dev/null
    assertEquals "(${label} ${status} ${extra}) row" "$expected" "$(stored_row)"
    assertEquals "(${label} ${status} ${extra}) event" '1' "$(db_query 'SELECT count(*) FROM event')"
    assertEquals "(${label} ${status} ${extra}) same id" '1' \
      "$(db_query 'SELECT count(*) FROM event e JOIN executed x ON x.id = e.id JOIN build_modules b ON b.id = e.id')"
    rm -f "$TELE_DB"
  done << 'EOT'
deploy:success::deploy|success|7|3|AAA,MID_X,ZED
deploy:failure::deploy|failure|7|3|AAA,MID_X,ZED
modules_deploy:success::modules_deploy|success|7|3|AAA,MID_X,ZED
modules_deploy:failure::modules_deploy|failure|7|3|AAA,MID_X,ZED
build:failure::build|failure|7|3|AAA,MID_X,ZED
deploy:success:none:deploy|success|7|0|
deploy:failure:none:deploy|failure|7|0|
EOT
}

function test_disabled_statistics_record_nothing()
{
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  configurations['disable_statistics_data_track']='yes'
  run_build
  assertEquals "($LINENO) disabled: event" '0' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) disabled: build_modules" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
}

# TEST_MODE only prints what would run (see cmd_manager), so nothing may be
# written to the database.
function test_build_in_test_mode_writes_nothing_to_the_database()
{
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  (build_kernel_main 'TEST_MODE') > "${TD}/build.out" 2> "${TD}/build.err" < /dev/null
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) build_modules" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
  assertEquals "($LINENO) executed" '0' "$(db_query 'SELECT count(*) FROM executed')"
  assertEquals "($LINENO) event" '0' "$(db_query 'SELECT count(*) FROM event')"
}

# Without the view (or the whole table) the build still reaches statistics_report
# and no build_modules row exists.
function test_build_falls_back_without_the_modules_objects()
{
  local label

  for label in 'old DB' 'view missing'; do
    make_db
    if [[ "$label" == 'old DB' ]]; then
      drop_build_modules_objects
    else
      sqlite3 "$TELE_DB" 'DROP VIEW build_modules_report;'
    fi
    write_fake_config "${FAKE_KERNEL}/.config"
    run_build
    assertEquals "(${label}) status" 0 "$?"
    assertEquals "(${label}) build kept" 'build|success' "$(db_query 'SELECT label_name || char(124) || status FROM statistics_report')"
    assertEquals "(${label}) event" '1' "$(db_query 'SELECT count(*) FROM event')"
    if [[ "$label" == 'view missing' ]]; then
      assertEquals "(${label}) no modules row" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
    fi
  done
}

# The none mode must not read the .config, whatever it holds.
function test_build_modules_record_none_ignores_the_config()
{
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  build_modules_record 1767323045 7 SILENT deploy success none > /dev/null
  assertEquals "($LINENO) count 0 and no names" 'deploy|success|7|0|' "$(stored_row)"
}

# flag : disable switch : extra argument
function test_build_modules_record_with_new_arguments_writes_nothing_when_off()
{
  local flag
  local disable
  local extra

  while IFS=':' read -r flag disable extra; do
    make_db
    write_fake_config "${FAKE_KERNEL}/.config"
    configurations['disable_statistics_data_track']="$disable"
    build_modules_record 1767323045 7 "$flag" deploy failure ${extra:+"$extra"} > /dev/null
    assertEquals "(${flag} ${disable} ${extra}) event" '0' "$(db_query 'SELECT count(*) FROM event')"
    assertEquals "(${flag} ${disable} ${extra}) executed" '0' "$(db_query 'SELECT count(*) FROM executed')"
    assertEquals "(${flag} ${disable} ${extra}) build_modules" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
    rm -f "$TELE_DB"
  done << 'EOT'
TEST_MODE:no:
TEST_MODE:no:none
SILENT:yes:
SILENT:yes:none
EOT
}

# On an old database the label and the status survive; no modules row exists.
function test_build_modules_record_falls_back_keeping_label_and_status()
{
  local label
  local status

  while IFS=':' read -r label status; do
    make_db
    drop_build_modules_objects
    write_fake_config "${FAKE_KERNEL}/.config"
    build_modules_record 1767323045 7 SILENT "$label" "$status" > /dev/null
    assertEquals "(${label} ${status}) kept" "${label}|${status}" "$(db_query 'SELECT label_name || char(124) || status FROM statistics_report')"
    assertEquals "(${label} ${status}) one event" '1' "$(db_query 'SELECT count(*) FROM event')"
    assertEquals "(${label} ${status}) one executed" '1' "$(db_query 'SELECT count(*) FROM executed')"
    rm -f "$TELE_DB"
  done << 'EOT'
deploy:failure
modules_deploy:success
EOT
}

# ------------------------------------------------------------------- deploy.sh

# deploy_main with every step that touches a target stubbed out; only the
# outcome (FAKE_DEPLOY_RC) and the recording are real.
function prepare_host_deploy_dir()
{
  :
}

function deploy_setup()
{
  return 0
}

function collect_target_info_for_deploy()
{
  :
}

function migrate_old_envs_to_base64()
{
  :
}

function signal_manager()
{
  :
}

function cleanup()
{
  :
}

function run_list_installed_kernels()
{
  return "${FAKE_DEPLOY_RC:-0}"
}

function run_kernel_uninstall()
{
  return "${FAKE_DEPLOY_RC:-0}"
}

function run_kernel_install()
{
  return "${FAKE_DEPLOY_RC:-0}"
}

function modules_install()
{
  return "${FAKE_DEPLOY_RC:-0}"
}

function build_kw_kernel_package()
{
  local -n tar_ref="$1"
  local -n image_ref="$2"

  tar_ref="${TD}/fake.kw.tar"
  image_ref='vmlinuz'
  : > "$tar_ref"
}

function run_deploy()
{
  (deploy_main 1 "$@") > "${TD}/deploy.out" 2> "${TD}/deploy.err" < /dev/null
}

# arguments (@@ is the temp dir) : outcome : expected executed rows : expected build_modules rows
function test_deploy_records_the_outcome_with_its_modules()
{
  local args
  local rc
  local executed
  local modules
  local -a argv

  while IFS=':' read -r args rc executed modules; do
    make_db
    write_fake_config "${FAKE_KERNEL}/.config"
    : > "${TD}/pkg.tar"
    FAKE_DEPLOY_RC="$rc"
    read -r -a argv <<< "${args//@@/${TD}}"
    run_deploy "${argv[@]}"
    assertEquals "(${args} ${rc}) executed" "$executed" "$(executed_rows)"
    assertEquals "(${args} ${rc}) build_modules" "$modules" \
      "$(db_query "SELECT coalesce(group_concat(module_count || char(124) || module_names, ';'), '') FROM build_modules")"
    assertEquals "(${args} ${rc}) one event per run" '1' "$(db_query 'SELECT count(*) FROM event')"
    rm -f "$TELE_DB"
  done << 'EOT'
--local:0:deploy|success:3|AAA,MID_X,ZED
--local:1:deploy|failure:3|AAA,MID_X,ZED
--local -m:0:modules_deploy|success:3|AAA,MID_X,ZED
--local -m:1:modules_deploy|failure:3|AAA,MID_X,ZED
--local -F @@/pkg.tar:0:deploy|success:0|
--local -F @@/pkg.tar:1:deploy|failure:0|
--local -F @@/pkg.tar -m:0:modules_deploy|success:0|
--local -F @@/pkg.tar -m:1:modules_deploy|failure:0|
--local -l:0:list|success:
--local -a:0:list|success:
--local -a:1:list|failure:
--local -s:0:list|success:
--local -s:1:list|failure:
--local -l:1:list|failure:
--local -u:0:uninstall|success:
--local -u:1:uninstall|failure:
EOT
}

# ------------------------------------------------- hostile and huge module names

# @label: name of the case, for the failure messages
# @name: module name as it appears after CONFIG_ and before =m
# Records a build whose .config holds a benign module and the given one. Nothing
# may run, the build must still be recorded, and the name is stored verbatim.
function assert_hostile_name_is_inert()
{
  local label="$1"
  local name="$2"
  local stored
  local expected

  make_db
  rm -f "${TD}/PWNED"
  printf '%s\n' 'CONFIG_AAA=m' "CONFIG_${name}=m" > "${FAKE_KERNEL}/.config"
  run_build
  assertEquals "(${label}) build status" 0 "$?"
  assertFalse "(${label}) nothing was executed" "[[ -e ${TD}/PWNED ]]"
  assertEquals "(${label}) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "(${label}) schema intact" '1' "$(db_query "SELECT count(*) FROM sqlite_master WHERE name = 'event'")"
  # build_modules_info sorts the names (byte order), so the expected value is
  # the same sort of the two names
  expected="$(printf '%s\n' AAA "$name" | LC_ALL=C sort | paste -sd, -)"
  stored="$(db_query 'SELECT module_names FROM build_modules')"
  assert_equals_helper "(${label}) stored verbatim" "$LINENO" "$expected" "$stored"
  assertEquals "(${label}) module count" 2 "$(db_query 'SELECT module_count FROM build_modules')"
}

function test_build_modules_hostile_names_are_inert()
{
  local long
  local name
  local -a names

  printf -v long '%*s' 5000 ''
  names=(
    "B\$(touch ${TD}/PWNED)"
    "B\`touch ${TD}/PWNED\`"
    "B'; DROP TABLE event; touch ${TD}/PWNED; --"
    "B\\n.shell touch ${TD}/PWNED"
    "B\\x41\\u0041%b%s"
    "B\\\\"
    'B--'
    ".shell touch ${TD}/PWNED"
    $'A\r.shell touch '"${TD}/PWNED"
    "${long// /L}"
  )
  for name in "${names[@]}"; do
    assert_hostile_name_is_inert "${name:0:40}" "$name"
  done
}

# The whole statement used to travel as one sqlite3 argument, above the 128 KiB
# limit of a single argument.
function test_build_with_thousands_of_modules()
{
  local i

  for ((i = 0; i < 7000; i++)); do
    printf 'CONFIG_BIGMODULE_NAME_%05d=m\n' "$i"
  done > "${FAKE_KERNEL}/.config"

  make_db
  run_build
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) row" '7000' "$(db_query 'SELECT module_count FROM build_modules')"
  assertEquals "($LINENO) names" '7000' "$(db_query "SELECT length(module_names) - length(replace(module_names, ',', '')) + 1 FROM build_modules")"
}

invoke_shunit
