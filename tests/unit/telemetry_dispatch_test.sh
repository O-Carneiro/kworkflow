#!/usr/bin/env bash

include './tests/unit/utils.sh'
include './tests/unit/samples/telemetry/helpers.sh'
include './src/lib/kw_db.sh'

# The dispatcher tests run a copy of ./kw: in repo mode kw takes KW_LIB_DIR from
# the directory its own file lives in, so a copied tree with stub telemetry
# files lets the real dispatcher run without touching the real sources.

function setUp()
{
  tele_setup
  TREE="${TD}/tree"
  mkdir -p "$TREE"
  cp "${PWD}/kw" "${TREE}/kw"
  cp -r "${PWD}/src" "${TREE}/src"
  ln -s "${PWD}/database" "${TREE}/database"
  ln -s "${PWD}/etc" "${TREE}/etc"
  unset -v KW_LIB_DIR KW_DB_DIR
  export CALLS="${TD}/calls"
  : > "$CALLS"

  cat > "${TREE}/src/lib/telemetry.sh" << 'STUB'
function telemetry_gate()
{
  printf 'gate:%s\n' "$*" >> "$CALLS"
}
STUB
  cat > "${TREE}/src/telemetry.sh" << 'STUB'
function telemetry_main()
{
  printf 'main:%s\n' "$*" >> "$CALLS"
}
STUB
}

function tearDown()
{
  tele_teardown
}

function run_kw()
{
  "${TREE}/kw" "$@" < /dev/null > "${TD}/kw.out" 2> "${TD}/kw.err"
  KW_RC="$?"
  KW_ERR="$(< "${TD}/kw.err")"
}

function test_dispatch_normal_command_runs_the_gate_with_the_action()
{
  run_kw h
  assertEquals "($LINENO)" 0 "$KW_RC"
  assert_equals_helper 'gate only' "$LINENO" 'gate:h' "$(< "$CALLS")"
}

function test_dispatch_gate_runs_before_the_command()
{
  # An unknown action reaches the `*)` arm, which prints the help; the gate
  # call is already recorded by then and receives the unknown word.
  run_kw bogus-action
  assert_equals_helper 'gate saw the action' "$LINENO" 'gate:bogus-action' "$(< "$CALLS")"
  assertEquals "($LINENO) command ran after the gate" 1 "$KW_RC"
}

function test_dispatch_telemetry_reaches_main_with_remaining_args()
{
  run_kw telemetry upload --dry-run
  assertEquals "($LINENO)" 0 "$KW_RC"
  # kw calls the gate for every action; telemetry_gate itself returns early for
  # `telemetry`, so the dispatcher test only checks the call and the order.
  assert_equals_helper 'gate then main' "$LINENO" $'gate:telemetry\nmain:upload --dry-run' "$(< "$CALLS")"
}

function test_dispatch_telemetry_without_args_reaches_main_without_args()
{
  run_kw telemetry
  assert_equals_helper 'gate then main' "$LINENO" $'gate:telemetry\nmain:' "$(< "$CALLS")"
}

function test_dispatch_missing_telemetry_lib_is_silent_and_the_command_still_runs()
{
  local with_stub_err
  local with_stub_out

  run_kw h
  with_stub_err="$KW_ERR"
  with_stub_out="$(< "${TD}/kw.out")"

  rm -f "${TREE}/src/lib/telemetry.sh"
  : > "$CALLS"
  run_kw h
  assertEquals "($LINENO)" 0 "$KW_RC"
  assert_equals_helper 'same stderr as with the lib' "$LINENO" "$with_stub_err" "$KW_ERR"
  assert_equals_helper 'same stdout as with the lib' "$LINENO" "$with_stub_out" "$(< "${TD}/kw.out")"
  assert_equals_helper 'no gate call' "$LINENO" '' "$(< "$CALLS")"
  assertNotContains "($LINENO) no shell error" "$KW_ERR" 'No such file'
  assertNotContains "($LINENO) no shell error" "$KW_ERR" 'command not found'
}

# ---------------------------------------------------------------- DB writes

function test_db_insert_into_event_succeeds_and_leaves_sent_at_null()
{
  local out
  local ret

  tele_make_db
  KW_DATA_DIR="$TELE_DATA_DIR"
  KW_DB_DIR="${PWD}/database"

  insert_into 'event' "('date','time')" "('2026-01-01','10:00:00')" > /dev/null 2>&1
  ret="$?"
  assertEquals "($LINENO) insert status" 0 "$ret"

  out="$(sqlite3 "$TELE_DB" "SELECT count(*) || '|' || count(sent_at) FROM event")"
  assert_equals_helper 'one row, sent_at NULL' "$LINENO" '1|0' "$out"
}

function test_db_insert_into_event_honours_the_busy_timeout()
{
  assertContains "($LINENO) pre_cmd sets a busy timeout" "$(< "${PWD}/database/pre_cmd.sql")" '.timeout 5000'
}

invoke_shunit
