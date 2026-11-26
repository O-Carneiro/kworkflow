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

# ------------------------------------------------------------ subcommand mapping

function test_main_maps_subcommands_to_kw_tele_calls()
{
  local args
  local expected
  local -a argv

  # kw telemetry arguments | kw_tele argv. Config flags and `info` go through
  # verbatim, `upload` is forced unless it is a dry run, and opt-in without a
  # terminal never prompts.
  while IFS='|' read -r args expected; do
    rm -f "${KW_TELE_STUB_DIR}/record"
    read -r -a argv <<< "$args"
    run_main "${argv[@]}"
    assertEquals "(${args}) status" 0 "$MAIN_RC"
    assert_equals_helper "kw telemetry ${args}" "$LINENO" "$expected" "$(tele_calls)"
  done << 'EOF'
upload|upload --force
upload --dry-run|upload --dry-run
opt-out|consent --set no
opt-in|consent --set yes
opt-in --include-history|consent --set yes --include-history
info|info
info --export|info --export
config|config
config --set-batch-size 10 --set-upload-interval 7200 --set-upload-backoff 60|config --set-batch-size 10 --set-upload-interval 7200 --set-upload-backoff 60
EOF

  rm -f "${KW_TELE_STUB_DIR}/record"
  run_main config --set-batch-size '1 0'
  assertEquals "($LINENO) argument with a space stays one argument" 3 "$(tele_call_field 'config --set-batch-size 1 0' argc)"
}

function test_main_opt_in_never_prompts_even_on_a_terminal()
{
  tele_write_config 'telemetry_consent=ask'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '' 'telemetry_main opt-in'
  assert_lacks "$LINENO" 'prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_equals_helper 'argv' "$LINENO" 'consent --set yes' "$(tele_calls)"
}

function test_main_passes_the_kw_environment_and_leaks_nothing()
{
  run_main upload
  assert_equals_helper 'KW_TELE_CONFIG' "$LINENO" "$TELE_CONFIG" "$(tele_call_field 'upload --force' KW_TELE_CONFIG)"
  assert_equals_helper 'KW_DATA_DIR' "$LINENO" "$TELE_DATA_DIR" "$(tele_call_field 'upload --force' KW_DATA_DIR)"
  assert_equals_helper 'KW_STATE_DIR' "$LINENO" "$TELE_STATE_DIR" "$(tele_call_field 'upload --force' KW_STATE_DIR)"
  assert_equals_helper 'KW_VERSION' "$LINENO" "$(head -n 1 ./src/VERSION)" "$(tele_call_field 'upload --force' KW_VERSION)"
  assertFalse "($LINENO) KW_TELE_CONFIG leaked" '[[ -v KW_TELE_CONFIG ]]'
  assertFalse "($LINENO) KW_VERSION leaked" '[[ -v KW_VERSION ]]'
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

function test_main_consent_on_a_terminal_prompts_when_not_yes()
{
  tele_write_config 'telemetry_consent=ask'
  tele_stub_set stdout.consent 'ask'
  tele_stub_set stdout.info $'pending_events=5\npending_since=2026-03-03'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '2\n' "telemetry_main consent > '${TD}/consent.stdout'"
  assert_has "$LINENO" 'prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_has "$LINENO" 'counts' "$TELE_PTY_OUT" '5 events recorded since 2026-03-03'
  assert_equals_helper 'calls' "$LINENO" $'consent\ninfo --pending\nconsent --set yes' "$(tele_calls)"
  assert_lacks "$LINENO" 'the prompt is on stderr, not stdout' "$(< "${TD}/consent.stdout")" 'Share kw usage telemetry?'
}

function test_main_consent_on_a_terminal_does_not_prompt_when_already_yes()
{
  tele_stub_set stdout.consent 'yes'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '' 'telemetry_main consent'
  assert_has "$LINENO" 'value shown' "$TELE_PTY_OUT" 'yes'
  assert_has "$LINENO" 'hint' "$TELE_PTY_OUT" 'opt-out'
  assert_lacks "$LINENO" 'no prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_equals_helper 'calls' "$LINENO" 'consent' "$(tele_calls)"
}

# Without a terminal the shim only shows the value: it must not call the prompt
# (which would read stdin), whatever the consent is.
function test_main_consent_without_a_terminal_never_prompts()
{
  local value

  for value in ask no; do
    rm -f "${KW_TELE_STUB_DIR}/record"
    tele_stub_set stdout.consent "$value"
    run_main consent
    assertEquals "(${value}) status" 0 "$MAIN_RC"
    assert_has "$LINENO" "${value}: value shown" "$MAIN_OUT" "$value"
    assert_lacks "$LINENO" "${value}: no prompt" "$(main_text)" 'Share kw usage telemetry?'
    assert_equals_helper "${value}: only the show call" "$LINENO" 'consent' "$(tele_calls)"
  done
}

# The prompt's own status does not change what `kw telemetry consent` returns.
function test_main_consent_returns_0_even_when_the_prompt_gets_no_answer()
{
  tele_stub_set stdout.consent 'ask'
  TELE_PTY_EXTRA='include ./src/telemetry.sh' tele_run_pty '' 'telemetry_main consent'
  assertEquals "($LINENO) status" 0 "$TELE_PTY_RC"
}

# ------------------------------------------------------------ exit code mapping

function test_main_exit_codes_get_their_messages()
{
  local code
  local sub
  local message

  # A DB exists, so the missing-DB warning cannot stand in for the exit-6 message.
  tele_make_db
  # kw_tele exit code | subcommand | message
  while IFS='|' read -r code sub message; do
    tele_stub_set exit "$code"
    run_main "$sub"
    assertEquals "(exit ${code} ${sub}) status" "$code" "$MAIN_RC"
    assert_has "$LINENO" "exit ${code} ${sub}" "$(main_text)" "$message"
  done << 'EOF'
3|upload|Telemetry is not enabled; run `kw telemetry opt-in`.
3|consent|Telemetry is not enabled; run `kw telemetry opt-in`.
4|info|kw database schema is outdated.
6|info|kw database not found.
1|upload|kw_tele exited with error code 1
130|upload|kw_tele exited with error code 130
EOF

  tele_stub_set exit 0
  run_main upload
  assertEquals "($LINENO) exit 0" 0 "$MAIN_RC"
  assert_lacks "$LINENO" 'exit 0 prints no complaint' "$(main_text)" 'exited with error code'
}

# ------------------------------------------------------- dispatch and usage

function test_main_unknown_subcommand_returns_22_with_usage()
{
  run_main frobnicate
  assertEquals "($LINENO)" 22 "$MAIN_RC"
  assert_has "$LINENO" 'names the offender' "$(main_text)" 'frobnicate'
  assert_has "$LINENO" 'usage' "$(main_text)" 'upload'
  assert_has "$LINENO" 'usage' "$(main_text)" 'opt-out'
  assertEquals "($LINENO) kw_tele not called" '' "$(tele_calls)"
}

function test_main_help_forms_print_the_usage_and_succeed()
{
  local form
  local -a argv

  for form in '' '-h' '--help'; do
    read -r -a argv <<< "$form"
    run_main "${argv[@]}"
    assertEquals "(help '${form}') status" 0 "$MAIN_RC"
    assert_has "$LINENO" "help '${form}'" "$(main_text)" 'telemetry opt-out'
  done
  assertEquals "($LINENO) kw_tele not called" '' "$(tele_calls)"
}

# ---------------------------------------------------------- missing kw_tele

function test_main_without_kw_tele_complains_and_returns_2()
{
  local saved="$PATH"
  local sub
  local results=''
  local expected=''

  # The asserts run after PATH is restored: shunit2 needs expr.
  tele_limited_path kw_tele
  PATH="$TELE_LIMITED_PATH"
  for sub in upload consent opt-in opt-out info config; do
    run_main "$sub"
    [[ "$(main_text)" == *kw_tele* ]] && results+="${sub}:${MAIN_RC} " || results+="${sub}:${MAIN_RC}:silent "
    expected+="${sub}:2 "
  done
  PATH="$saved"
  assert_equals_helper 'every subcommand returns 2 and names kw_tele' "$LINENO" "$expected" "$results"
  assertEquals "($LINENO) nothing called" '' "$(tele_calls)"
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

invoke_shunit
