#!/usr/bin/env bash

include './tests/unit/utils.sh'
include './tests/unit/samples/telemetry/helpers.sh'

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

function test_dispatch_runs_the_gate_with_the_action()
{
  run_kw h
  assertEquals "($LINENO)" 0 "$KW_RC"
  assert_equals_helper 'gate only' "$LINENO" 'gate:h' "$(< "$CALLS")"
}

# An unknown action reaches the `*)` arm, which prints the help; the gate call
# is already recorded by then and receives the unknown word.
function test_dispatch_unknown_action_still_runs_the_gate()
{
  run_kw bogus-action
  assert_equals_helper 'gate saw the action' "$LINENO" 'gate:bogus-action' "$(< "$CALLS")"
  assertEquals "($LINENO) the command ran after the gate" 1 "$KW_RC"
}

# kw calls the gate for every action; telemetry_gate itself returns early for
# `telemetry`, so this only checks the calls and their order.
function test_dispatch_telemetry_reaches_main_with_the_remaining_args()
{
  run_kw telemetry upload --dry-run
  assertEquals "($LINENO)" 0 "$KW_RC"
  assert_equals_helper 'gate then main' "$LINENO" $'gate:telemetry\nmain:upload --dry-run' "$(< "$CALLS")"

  : > "$CALLS"
  run_kw telemetry
  assert_equals_helper 'gate then main, no args' "$LINENO" $'gate:telemetry\nmain:' "$(< "$CALLS")"
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

invoke_shunit
