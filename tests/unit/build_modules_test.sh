#!/usr/bin/env bash

include './src/build.sh' > /dev/null
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

# ------------------------------------------------------------------ schema

function test_schema_declares_build_modules_objects()
{
  make_db
  assertEquals "($LINENO) table" 'build_modules' "$(db_query "SELECT name FROM sqlite_master WHERE type='table' AND name='build_modules'")"
  assertEquals "($LINENO) view" 'build_modules_report' "$(db_query "SELECT name FROM sqlite_master WHERE type='view' AND name='build_modules_report'")"
  assertEquals "($LINENO) columns" 'id,module_count,module_names' \
    "$(db_query "SELECT group_concat(name) FROM pragma_table_info('build_modules')")"
  assertEquals "($LINENO) fk cascade" 'event|CASCADE' \
    "$(db_query "SELECT \"table\" || '|' || on_delete FROM pragma_foreign_key_list('build_modules')")"
}

function insert_report_row()
{
  sqlite3 -cmd 'PRAGMA foreign_keys = 1' "$TELE_DB" "INSERT INTO build_modules_report (label_name, status, date, time, elapsed_time_in_secs, module_count, module_names) VALUES ('build', 'success', '2026-01-02', '03:04:05', 7, 2, 'a,b');"
}

function test_schema_view_trigger_inserts_event_executed_and_build_modules()
{
  make_db
  insert_report_row
  assertEquals "($LINENO) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) executed" 'build|success|7' \
    "$(db_query "SELECT c.name || '|' || s.name || '|' || x.elapsed_time_in_secs FROM executed x JOIN command_label c ON c.id = x.command_label_id JOIN status s ON s.id = x.status_id")"
  assertEquals "($LINENO) build_modules" '2|a,b' "$(db_query "SELECT module_count || '|' || module_names FROM build_modules")"
  assertEquals "($LINENO) same id" '1' \
    "$(db_query 'SELECT count(*) FROM event e JOIN executed x ON x.id = e.id JOIN build_modules b ON b.id = e.id')"
  assertEquals "($LINENO) pending upload" '1' "$(db_query 'SELECT count(*) FROM event WHERE sent_at IS NULL')"
}

function test_schema_trigger_is_atomic_when_build_modules_insert_fails()
{
  make_db
  sqlite3 -cmd 'PRAGMA foreign_keys = 1' "$TELE_DB" "INSERT INTO build_modules_report (label_name, status, date, time, elapsed_time_in_secs, module_count, module_names) VALUES ('build', 'success', '2026-01-02', '03:04:05', 7, 'x', 'a,b');" > /dev/null 2>&1
  insert_report_row
  assertEquals "($LINENO) two inserts, two events" '2' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) every event has its module row" '2' "$(db_query 'SELECT count(*) FROM build_modules')"
}

function test_schema_deleting_an_event_cascades_to_build_modules()
{
  make_db
  insert_report_row
  sqlite3 -cmd 'PRAGMA foreign_keys = 1' "$TELE_DB" 'DELETE FROM executed; DELETE FROM event;'
  assertEquals "($LINENO)" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
}

function drop_build_modules_objects()
{
  sqlite3 "$TELE_DB" 'DROP VIEW IF EXISTS build_modules_report; DROP TABLE IF EXISTS build_modules;'
}

function test_ensure_schema_adds_build_modules_to_an_old_db()
{
  make_db
  drop_build_modules_objects
  assertEquals "($LINENO) precondition" '0' "$(db_query "SELECT count(*) FROM sqlite_master WHERE name LIKE 'build_modules%'")"

  telemetry_paths
  telemetry_ensure_schema > /dev/null 2>&1
  assertEquals "($LINENO) status" 0 "$?"
  insert_report_row
  assertEquals "($LINENO) usable" '2|a,b' "$(db_query "SELECT module_count || '|' || module_names FROM build_modules")"
}

function test_ensure_schema_build_modules_is_idempotent()
{
  make_db
  drop_build_modules_objects
  telemetry_paths
  telemetry_ensure_schema > /dev/null 2>&1
  insert_report_row
  telemetry_ensure_schema > "${TD}/o" 2> "${TD}/e"
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) silent" '' "$(< "${TD}/o")$(< "${TD}/e")"
  assertEquals "($LINENO) data kept" '1' "$(db_query 'SELECT count(*) FROM build_modules')"
}

# ------------------------------------------------------------------- build.sh

function test_get_build_config_path_defaults_to_dot_config()
{
  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']=''
  assertEquals "($LINENO)" '.config' "$(get_build_config_path)"
}

function test_get_build_config_path_prefers_the_output_dir_config()
{
  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']="${TD}/out"
  assertEquals "($LINENO) no config there" '.config' "$(get_build_config_path)"
  write_fake_config "${TD}/out/.config"
  assertEquals "($LINENO) config there" "${TD}/out/.config" "$(get_build_config_path)"
}

# build_modules_info is assumed to print the count on line 1 and the names on line 2.
function test_build_modules_info_counts_and_sorts_the_modules()
{
  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']=''
  write_fake_config "${FAKE_KERNEL}/.config"
  assertEquals "($LINENO)" "3"$'\n'"AAA,MID_X,ZED" "$(build_modules_info)"
}

function test_build_modules_info_without_a_config_gives_zero_and_empty()
{
  local -a lines
  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']=''
  mapfile -t lines < <(build_modules_info)
  assertEquals "($LINENO) count" '0' "${lines[0]}"
  assertEquals "($LINENO) names" '' "${lines[1]:-}"
}

function test_build_success_records_one_build_modules_row()
{
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  run_build
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) executed" 'build|success' \
    "$(db_query "SELECT c.name || '|' || s.name FROM executed x JOIN command_label c ON c.id = x.command_label_id JOIN status s ON s.id = x.status_id")"
  assertEquals "($LINENO) build_modules" '3|AAA,MID_X,ZED' \
    "$(db_query "SELECT module_count || '|' || module_names FROM build_modules")"
}

function test_build_success_without_config_records_zero_modules()
{
  make_db
  run_build
  assertEquals "($LINENO) row" '0|' "$(db_query "SELECT module_count || '|' || coalesce(module_names, '') FROM build_modules")"
}

function test_build_failure_records_no_build_modules_row()
{
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  FAKE_MAKE_RC=2
  run_build
  assertEquals "($LINENO) event" '1' "$(db_query "SELECT count(*) FROM executed x JOIN status s ON s.id = x.status_id WHERE s.name = 'failure'")"
  assertEquals "($LINENO) build_modules" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
}

function test_build_with_statistics_disabled_records_nothing()
{
  make_db
  write_fake_config "${FAKE_KERNEL}/.config"
  configurations['disable_statistics_data_track']='yes'
  run_build
  assertEquals "($LINENO) event" '0' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) build_modules" '0' "$(db_query 'SELECT count(*) FROM build_modules')"
}

# --------------------------------------------------------------- regressions

function get_kernel_release()
{
  printf '%s\n' '5.4.0-rc7-test'
}

function get_kernel_version()
{
  printf '%s\n' '5.4.0'
}

function test_build_on_an_old_db_still_records_the_build_in_statistics_report()
{
  make_db
  drop_build_modules_objects
  write_fake_config "${FAKE_KERNEL}/.config"
  run_build
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) event" '1' "$(db_query 'SELECT count(*) FROM event')"
  assertEquals "($LINENO) executed" 'build|success' \
    "$(db_query "SELECT label_name || '|' || status FROM statistics_report")"
}

function test_ensure_schema_without_kw_db_dir_is_silent_and_succeeds()
{
  make_db
  drop_build_modules_objects
  unset -v KW_DB_DIR
  telemetry_paths
  telemetry_ensure_schema > "${TD}/o" 2> "${TD}/e"
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) silent" '' "$(< "${TD}/o")$(< "${TD}/e")"
}

function test_ensure_schema_with_missing_kwdb_sql_is_silent_and_succeeds()
{
  make_db
  drop_build_modules_objects
  KW_DB_DIR="${TD}/empty_db_dir"
  mkdir -p "$KW_DB_DIR"
  telemetry_paths
  telemetry_ensure_schema > "${TD}/o" 2> "${TD}/e"
  assertEquals "($LINENO) status" 0 "$?"
  assertEquals "($LINENO) silent" '' "$(< "${TD}/o")$(< "${TD}/e")"
}

function test_build_info_module_count_matches_build_modules_info()
{
  local shown
  local -a lines

  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']=''
  printf '%s\n' '# CONFIG_X is not set' 'CONFIG_Y=y' 'CONFIG_Z=m # c' 'CONFIG_W=m' > "${FAKE_KERNEL}/.config"
  mapfile -t lines < <(build_modules_info)
  shown="$(build_info '' | grep 'Total modules')"
  assertEquals "($LINENO)" "  Total modules to be compiled: ${lines[0]}" "$shown"
}

function test_build_modules_info_ignores_non_module_lines()
{
  local -a lines

  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']=''
  printf '%s\n' '# CONFIG_C=m' '# CONFIG_X is not set' 'CONFIG_Y=y' 'CONFIG_Q="m"' 'CONFIG_S="a=m"' 'CONFIG_OK=m' > "${FAKE_KERNEL}/.config"
  mapfile -t lines < <(build_modules_info)
  assertEquals "($LINENO) count" '1' "${lines[0]}"
  assertEquals "($LINENO) names" 'OK' "${lines[1]:-}"
}

function test_build_modules_info_empty_config()
{
  local -a lines

  options_values['ENV_PATH_KBUILD_OUTPUT_FLAG']=''
  : > "${FAKE_KERNEL}/.config"
  mapfile -t lines < <(build_modules_info)
  assertEquals "($LINENO) count" '0' "${lines[0]}"
  assertEquals "($LINENO) names" '' "${lines[1]:-}"
}

invoke_shunit
