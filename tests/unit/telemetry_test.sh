#!/usr/bin/env bash

include './tests/unit/utils.sh'
include './tests/unit/samples/telemetry/helpers.sh'
include './src/lib/kwio.sh'
include './src/lib/kwlib.sh'
include './src/telemetry.sh'

function setUp()
{
  endSkipping
  tele_setup
  tele_consent_yes
  MAIN_RC=''
  MAIN_OUT=''
  MAIN_ERR=''
}

function tearDown()
{
  tele_teardown
}

# Runs telemetry_main without a terminal and keeps both streams.
function run_main()
{
  telemetry_main "$@" < /dev/null > "${TD}/main.out" 2> "${TD}/main.err"
  MAIN_RC="$?"
  MAIN_OUT="$(< "${TD}/main.out")"
  MAIN_ERR="$(< "${TD}/main.err")"
}

# @return: stdout and stderr of the last run_main call
function main_text()
{
  printf '%s\n%s' "$MAIN_OUT" "$MAIN_ERR"
}

# ---------------------------------------------------------------- fixtures

function test_fixture_stub_is_first_on_path_and_records()
{
  assert_equals_helper 'stub on PATH' "$LINENO" "${TD}/stubbin/kw_tele" "$(command -v kw_tele)"
  kw_tele info --export > /dev/null
  assert_equals_helper 'argv recorded' "$LINENO" 'info --export' "$(tele_calls)"
}

function test_fixture_pty_driver_runs_a_snippet_with_a_terminal()
{
  tele_run_pty '' '[[ -t 0 && -t 2 ]] && echo TTY_OK'
  assert_has "$LINENO" 'both streams are terminals' "$TELE_PTY_OUT" 'TTY_OK'
  assertEquals "($LINENO) status" 0 "$TELE_PTY_RC"
}

# ------------------------------------------------------------ subcommand mapping

function test_main_upload_forces_an_upload()
{
  run_main upload
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'upload --force' "$(tele_calls)"
}

function test_main_upload_dry_run_maps_to_dry_run()
{
  run_main upload --dry-run
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'upload --dry-run' "$(tele_calls)"
}

function test_main_upload_dry_run_passes_the_output_through()
{
  tele_stub_set stdout.upload '{"resourceLogs": []}'
  run_main upload --dry-run
  assert_has "$LINENO" 'stdout' "$MAIN_OUT" '{"resourceLogs": []}'
}

function test_main_opt_out_sets_no()
{
  run_main opt-out
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'consent --set no' "$(tele_calls)"
}

function test_main_opt_in_without_a_terminal_sets_yes_without_history()
{
  run_main opt-in
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'consent --set yes' "$(tele_calls)"
}

function test_main_opt_in_include_history_passes_the_flag()
{
  run_main opt-in --include-history
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'consent --set yes --include-history' "$(tele_calls)"
}

function test_main_opt_in_never_prompts_even_on_a_terminal()
{
  tele_write_config 'telemetry_consent=ask'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '' 'telemetry_main opt-in'
  assert_lacks "$LINENO" 'prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_equals_helper 'argv' "$LINENO" 'consent --set yes' "$(tele_calls)"
}

function test_main_info_is_passed_through()
{
  tele_stub_set stdout.info 'summary line'
  run_main info
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'info' "$(tele_calls)"
  assert_has "$LINENO" 'stdout' "$MAIN_OUT" 'summary line'
}

function test_main_info_export_is_passed_through()
{
  run_main info --export
  assert_equals_helper 'argv' "$LINENO" 'info --export' "$(tele_calls)"
}

function test_main_config_flags_are_passed_through_verbatim()
{
  run_main config --set-batch-size 10 --set-upload-interval 7200 --set-upload-backoff 60
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'config --set-batch-size 10 --set-upload-interval 7200 --set-upload-backoff 60' "$(tele_calls)"
}

function test_main_config_without_flags_is_passed_through()
{
  tele_stub_set stdout.config $'telemetry_consent=yes\npending_events=0'
  run_main config
  assert_equals_helper 'argv' "$LINENO" 'config' "$(tele_calls)"
  assert_has "$LINENO" 'stdout' "$MAIN_OUT" 'pending_events=0'
}

function test_main_config_keeps_arguments_with_spaces_intact()
{
  run_main config --set-batch-size '1 0'
  assertEquals "($LINENO) argc" 3 "$(tele_call_field 'config --set-batch-size 1 0' argc)"
}

function test_main_calls_kw_tele_with_the_kw_environment()
{
  run_main upload
  assert_equals_helper 'KW_TELE_CONFIG' "$LINENO" "$TELE_CONFIG" "$(tele_call_field 'upload --force' KW_TELE_CONFIG)"
  assert_equals_helper 'KW_DATA_DIR' "$LINENO" "$TELE_DATA_DIR" "$(tele_call_field 'upload --force' KW_DATA_DIR)"
  assert_equals_helper 'KW_STATE_DIR' "$LINENO" "$TELE_STATE_DIR" "$(tele_call_field 'upload --force' KW_STATE_DIR)"
  assert_equals_helper 'KW_VERSION' "$LINENO" "$(head -n 1 ./src/VERSION)" "$(tele_call_field 'upload --force' KW_VERSION)"
}

function test_main_does_not_leak_kw_tele_variables_into_the_caller_shell()
{
  run_main upload
  assert_equals_helper 'kw_tele was called' "$LINENO" 'upload --force' "$(tele_calls)"
  assertFalse "($LINENO) KW_TELE_CONFIG" '[[ -v KW_TELE_CONFIG ]]'
  assertFalse "($LINENO) KW_VERSION" '[[ -v KW_VERSION ]]'
}

# -------------------------------------------------------------------- consent

function test_main_consent_without_a_terminal_only_prints()
{
  tele_write_config 'telemetry_consent=ask'
  tele_stub_set stdout.consent 'ask'
  run_main consent
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'consent' "$(tele_calls)"
  assert_has "$LINENO" 'value shown' "$MAIN_OUT" 'ask'
  assert_lacks "$LINENO" 'no prompt' "$(main_text)" 'Choice [3]:'
}

function test_main_consent_on_a_terminal_prints_then_prompts_when_not_yes()
{
  tele_write_config 'telemetry_consent=ask'
  tele_stub_set stdout.consent 'ask'
  tele_stub_set stdout.info $'pending_events=5\npending_since=2026-03-03'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '2\n' 'telemetry_main consent'
  assert_has "$LINENO" 'value shown' "$TELE_PTY_OUT" 'ask'
  assert_has "$LINENO" 'prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_has "$LINENO" 'counts' "$TELE_PTY_OUT" '5 events recorded since 2026-03-03'
  assert_equals_helper 'calls' "$LINENO" $'consent\ninfo --pending\nconsent --set yes' "$(tele_calls)"
}

function test_main_consent_on_a_terminal_when_already_yes_prints_and_points_to_opt_out()
{
  tele_stub_set stdout.consent 'yes'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '' 'telemetry_main consent'
  assert_has "$LINENO" 'value shown' "$TELE_PTY_OUT" 'yes'
  assert_has "$LINENO" 'hint' "$TELE_PTY_OUT" 'opt-out'
  assert_lacks "$LINENO" 'no prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_equals_helper 'calls' "$LINENO" 'consent' "$(tele_calls)"
}

function test_main_consent_on_a_terminal_with_no_answer_changes_nothing()
{
  tele_write_config 'telemetry_consent=ask'
  tele_stub_set stdout.consent 'ask'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '' 'telemetry_main consent'
  assert_has "$LINENO" 'prompt shown' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_lacks "$LINENO" 'nothing written' "$(tele_calls)" '--set'
}

# ------------------------------------------------------------ exit code mapping

function test_main_exit_3_explains_that_telemetry_is_not_enabled()
{
  tele_stub_set exit 3
  run_main upload
  assertEquals "($LINENO)" 3 "$MAIN_RC"
  assert_has "$LINENO" 'message' "$(main_text)" 'Telemetry is not enabled; run `kw telemetry opt-in`.'
}

function test_main_exit_4_explains_that_the_schema_is_outdated()
{
  tele_stub_set exit 4
  run_main info
  assertEquals "($LINENO)" 4 "$MAIN_RC"
  assert_has "$LINENO" 'message' "$(main_text)" 'kw database schema is outdated.'
}

function test_main_exit_6_explains_that_the_database_is_missing()
{
  tele_stub_set exit 6
  run_main info
  assertEquals "($LINENO)" 6 "$MAIN_RC"
  assert_has "$LINENO" 'message' "$(main_text)" 'kw database not found.'
}

function test_main_other_nonzero_codes_get_the_generic_message()
{
  local code

  for code in 1 2 5 7 130; do
    tele_stub_set exit "$code"
    run_main upload
    assertEquals "($LINENO) code ${code}" "$code" "$MAIN_RC"
    assert_has "$LINENO" "code ${code}" "$(main_text)" "kw_tele exited with error code ${code}"
  done
}

function test_main_exit_0_prints_no_error_message()
{
  run_main upload
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_lacks "$LINENO" 'no complaint' "$(main_text)" 'exited with error code'
  assert_lacks "$LINENO" 'no complaint' "$(main_text)" 'not enabled'
}

function test_main_specific_codes_do_not_also_get_the_generic_message()
{
  tele_stub_set exit 3
  run_main upload
  assertEquals "($LINENO)" 3 "$MAIN_RC"
  assert_lacks "$LINENO" 'generic' "$(main_text)" 'exited with error code'
}

# ------------------------------------------------------- dispatch and usage

function test_main_unknown_subcommand_returns_22_with_usage()
{
  run_main frobnicate
  assertEquals "($LINENO)" 22 "$MAIN_RC"
  assert_has "$LINENO" 'usage' "$(main_text)" 'upload'
  assert_has "$LINENO" 'usage' "$(main_text)" 'opt-out'
  assertEquals "($LINENO) kw_tele not called" '' "$(tele_calls)"
}

function test_main_unknown_subcommand_names_the_offender()
{
  run_main frobnicate
  assert_has "$LINENO" 'complaint' "$(main_text)" 'frobnicate'
}

function test_main_help_forms_print_usage_without_calling_kw_tele()
{
  local form

  for form in -h --help; do
    run_main "$form"
    assertEquals "($LINENO) ${form} status" 0 "$MAIN_RC"
    assert_has "$LINENO" "${form} usage" "$(main_text)" 'upload'
    assert_has "$LINENO" "${form} usage" "$(main_text)" 'consent'
    assert_has "$LINENO" "${form} usage" "$(main_text)" 'config'
  done
  run_main
  assert_has "$LINENO" 'no args: usage' "$(main_text)" 'upload'
  assertEquals "($LINENO) kw_tele not called" '' "$(tele_calls)"
}

# ---------------------------------------------------------- missing kw_tele

function test_main_without_kw_tele_complains_and_returns_2()
{
  local saved="$PATH"

  tele_limited_path kw_tele
  PATH="$TELE_LIMITED_PATH"
  run_main upload
  PATH="$saved"
  assertEquals "($LINENO)" 2 "$MAIN_RC"
  assert_has "$LINENO" 'complaint' "$(main_text)" 'kw_tele'
  assertEquals "($LINENO) nothing called" '' "$(tele_calls)"
}

function test_main_without_kw_tele_returns_2_for_every_subcommand()
{
  local saved="$PATH"
  local sub

  tele_limited_path kw_tele
  PATH="$TELE_LIMITED_PATH"
  for sub in upload consent opt-in opt-out info config; do
    run_main "$sub"
    assertEquals "($LINENO) ${sub}" 2 "$MAIN_RC"
  done
  PATH="$saved"
}

# ---------------------------------------------------------------- schema guard

function test_main_migrates_the_schema_before_calling_kw_tele()
{
  tele_make_db legacy
  run_main info
  tele_db_has_sent_at
  assertEquals "($LINENO) sent_at added" 0 "$?"
  assert_equals_helper 'argv' "$LINENO" 'info' "$(tele_calls)"
}

function test_main_with_a_missing_database_only_warns_and_still_runs_kw_tele()
{
  run_main info
  assertEquals "($LINENO)" 0 "$MAIN_RC"
  assert_equals_helper 'argv' "$LINENO" 'info' "$(tele_calls)"
  assertFalse "($LINENO) DB not created" "[[ -e ${TELE_DB} ]]"
}

function test_main_unknown_subcommand_does_not_need_a_database()
{
  run_main nope
  assertEquals "($LINENO)" 22 "$MAIN_RC"
}

invoke_shunit
