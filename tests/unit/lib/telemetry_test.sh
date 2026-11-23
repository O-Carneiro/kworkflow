#!/usr/bin/env bash

include './tests/unit/utils.sh'
include './tests/unit/samples/telemetry/helpers.sh'
include './src/lib/kwio.sh'
include './src/lib/kwlib.sh'
include './src/lib/telemetry.sh'

function setUp()
{
  endSkipping
  tele_setup
  GATE_RC=''
  GATE_OUT=''
  GATE_ERR=''
}

function tearDown()
{
  tele_teardown
}

# Runs the gate in the current shell (so leaks would be visible) without a
# terminal, and checks what must hold for every run: status 0, empty stdout.
#
# GATE_PATH, when set, replaces PATH for the call only: the assertions need
# the full PATH.
#
# @action: First argument of the kw command
# @line: $LINENO of the caller
function run_gate()
{
  local action="$1"
  local line="${2:-0}"

  PATH="${GATE_PATH:-$PATH}" telemetry_gate "$action" < /dev/null > "${TD}/gate.out" 2> "${TD}/gate.err"
  GATE_RC="$?"
  GATE_OUT="$(< "${TD}/gate.out")"
  GATE_ERR="$(< "${TD}/gate.err")"
  assertEquals "(${line}) the gate must always return 0" 0 "$GATE_RC"
  assertEquals "(${line}) the gate must not print to stdout" '' "$GATE_OUT"
}

# @line: $LINENO of the caller
# @expected: spawned, 'not spawned' or 'spawn file only'
# @label: Description of the scenario
function assert_gate_outcome()
{
  local line="$1"
  local expected="$2"
  local label="$3"
  local actual

  actual="$(tele_spawn_outcome)"
  assertEquals "(${line}) ${label}" "$expected" "$actual"
}

# Succeeds when the variable is exported.
function is_exported()
{
  local declaration

  declaration="$(declare -p "$1" 2> /dev/null)" || return 1
  declaration="${declaration#declare -}"
  [[ "${declaration%% *}" == *x* ]]
}

# ---------------------------------------------------------------- fixtures

function test_fixture_stub_records_argv_and_env()
{
  local call

  KW_TELE_NOW=12345 KW_DATA_DIR=/d KW_STATE_DIR=/s KW_TELE_CONFIG=/c KW_VERSION=v9 kw_tele info --pending
  assertEquals "($LINENO)" 0 "$?"
  call="$(< "${KW_TELE_STUB_DIR}/record")"
  assert_has "$LINENO" 'argv' "$call" 'argv=info --pending'$'\t'
  assert_has "$LINENO" 'env' "$call" $'\tKW_DATA_DIR=/d\tKW_STATE_DIR=/s\tKW_TELE_CONFIG=/c\tKW_VERSION=v9\t'
  assert_equals_helper 'stub is the first kw_tele on PATH' "$LINENO" "${TD}/stubbin/kw_tele" "$(command -v kw_tele)"
}

function test_fixture_stub_prints_and_exits_as_configured()
{
  local output
  local ret

  tele_stub_set stdout.info 'pending_events=3'
  tele_stub_set exit.info 6
  output="$(kw_tele info)"
  ret="$?"
  assertEquals "($LINENO)" 6 "$ret"
  assert_equals_helper 'stdout' "$LINENO" 'pending_events=3' "$output"
  kw_tele consent > /dev/null
  assertEquals "($LINENO) default exit code" 0 "$?"
}

function test_fixture_db_helper_builds_kwdb_sql()
{
  local tables

  tele_make_db
  tables="$(sqlite3 "$TELE_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('event','executed','timebox')")"
  assertEquals "($LINENO) tables from kwdb.sql" 3 "$tables"
  tele_db_has_sent_at
  assertEquals "($LINENO) sent_at column on the current DB" 0 "$?"
  tele_make_db legacy
  tele_db_has_sent_at
  assertEquals "($LINENO) legacy DB has no sent_at" 1 "$?"
}

function test_fixture_limited_path_leaves_out_tools()
{
  tele_limited_path setsid kw_tele
  assertNull "($LINENO)" "$(PATH="$TELE_LIMITED_PATH" command -v setsid)"
  assertNull "($LINENO)" "$(PATH="$TELE_LIMITED_PATH" command -v kw_tele)"
  assertNotNull "($LINENO)" "$(PATH="$TELE_LIMITED_PATH" command -v timeout)"
}

# ----------------------------------------------------------- database schema

function test_kwdb_sql_declares_sent_at_without_an_index()
{
  local sql

  sql="$(< ./database/kwdb.sql)"
  assert_has "$LINENO" 'event table needs the column' "$sql" '"sent_at" INTEGER'
  assert_lacks "$LINENO" 'kwdb.sql re-runs on old DBs, so no index there' "$sql" 'event_unsent_idx'
}

function test_pre_cmd_sql_waits_on_a_busy_database()
{
  assert_has "$LINENO" 'busy timeout' "$(< ./database/pre_cmd.sql)" '.timeout 5000'
}

# ------------------------------------------------------------ telemetry_read_kv

function test_read_kv_parses_plain_lines_and_last_line_without_newline()
{
  local -A kv=()
  local file="${TD}/kv"

  printf 'a=1\nb=2' > "$file"
  telemetry_read_kv "$file" kv
  assertEquals "($LINENO)" 0 "$?"
  assert_equals_helper 'a' "$LINENO" '1' "${kv[a]-<unset>}"
  assert_equals_helper 'last line without newline' "$LINENO" '2' "${kv[b]-<unset>}"
  assert_equals_helper 'size' "$LINENO" '2' "${#kv[@]}"
}

function test_read_kv_strips_crlf_and_trims_whitespace()
{
  local -A kv=()
  local file="${TD}/kv"

  printf 'a=1\r\n  b  =   two words  \r\nc=3\r' > "$file"
  telemetry_read_kv "$file" kv
  assert_equals_helper 'a' "$LINENO" '1' "${kv[a]-<unset>}"
  assert_equals_helper 'trimmed key and value, inner space kept' "$LINENO" 'two words' "${kv[b]-<unset>}"
  assert_equals_helper 'CR on an unterminated last line' "$LINENO" '3' "${kv[c]-<unset>}"
}

function test_read_kv_ignores_comments_and_blank_lines()
{
  local -A kv=()
  local file="${TD}/kv"

  printf '# a=1\n\n   \nb=2\n#c=3\n' > "$file"
  telemetry_read_kv "$file" kv
  assert_equals_helper 'only b' "$LINENO" 'b' "${!kv[*]}"
}

function test_read_kv_last_duplicate_wins()
{
  local -A kv=()
  local file="${TD}/kv"

  printf 'a=1\na=2\nb=x\na=3\n' > "$file"
  telemetry_read_kv "$file" kv
  assert_equals_helper 'a' "$LINENO" '3' "${kv[a]-<unset>}"
}

function test_read_kv_splits_on_first_equals_and_keeps_inline_comments()
{
  local -A kv=()
  local file="${TD}/kv"

  printf 'endpoint=http://h:1/p?a=b=c\nn=5 # not a comment\n' > "$file"
  telemetry_read_kv "$file" kv
  assert_equals_helper 'url' "$LINENO" 'http://h:1/p?a=b=c' "${kv[endpoint]-<unset>}"
  assert_equals_helper 'inline comment' "$LINENO" '5 # not a comment' "${kv[n]-<unset>}"
}

function test_read_kv_keeps_empty_values_and_is_case_sensitive()
{
  local -A kv=()
  local file="${TD}/kv"

  printf 'instance_id=\nKey=1\n' > "$file"
  telemetry_read_kv "$file" kv
  assert_equals_helper 'empty value is present' "$LINENO" '' "${kv[instance_id]-<unset>}"
  assert_equals_helper 'key is case-sensitive' "$LINENO" '<unset>' "${kv[key]-<unset>}"
  assert_equals_helper 'Key' "$LINENO" '1' "${kv[Key]-<unset>}"
}

function test_read_kv_missing_file_gives_empty_array_and_returns_0()
{
  local -A kv=([stale]=1)

  telemetry_read_kv "${TD}/nope" kv
  assertEquals "($LINENO)" 0 "$?"
  assert_equals_helper 'empty array' "$LINENO" '0' "${#kv[@]}"
}

function test_read_kv_empty_file_gives_empty_array()
{
  local -A kv=([stale]=1)

  : > "${TD}/kv"
  telemetry_read_kv "${TD}/kv" kv
  assertEquals "($LINENO)" 0 "$?"
  assert_equals_helper 'empty array' "$LINENO" '0' "${#kv[@]}"
}

# Runs telemetry_read_kv in a fresh function scope whose only locals are named
# outside the list under test, so unsetting the array name cannot hit them.
function read_kv_into_array_named()
{
  local _kvpath="$1"
  local _kvname="$2"

  unset -v "$_kvname"
  declare -A "$_kvname"
  telemetry_read_kv "$_kvpath" "$_kvname" || return 1
  local -n _kvref="$_kvname"
  printf '%s' "${_kvref[a]-<unset>}"
}

function test_read_kv_works_with_caller_arrays_named_like_common_locals()
{
  local _kvpath="${TD}/kv"
  local _kvname
  local _kvout

  printf 'a=1\n' > "$_kvpath"
  for _kvname in line key value file path k v i; do
    _kvout="$(read_kv_into_array_named "$_kvpath" "$_kvname")"
    assertEquals "($LINENO) return for array ${_kvname}" 0 "$?"
    assert_equals_helper "array ${_kvname}" "$LINENO" '1' "$_kvout"
  done
}

function test_read_kv_does_not_execute_keys_or_values()
{
  local -A kv=()
  local file="${TD}/kv"

  printf '$(touch %s/pwned)=1\na[$(touch %s/pwned2)]=2\nb=`touch %s/pwned3`\n' "$TD" "$TD" "$TD" > "$file"
  telemetry_read_kv "$file" kv
  assertEquals "($LINENO)" 0 "$?"
  assertFalse "($LINENO) command substitution ran" "[[ -e ${TD}/pwned || -e ${TD}/pwned2 || -e ${TD}/pwned3 ]]"
}

# ------------------------------------------------------------- telemetry_paths

function test_paths_use_xdg_directories_and_kworkflow_name()
{
  export KWORKFLOW='.kw'
  telemetry_paths
  assert_equals_helper 'config' "$LINENO" "${XDG_CONFIG_HOME}/.kw/telemetry.config" "$TELEMETRY_CONFIG"
  assert_equals_helper 'state' "$LINENO" "${XDG_STATE_HOME}/.kw/telemetry.state" "$TELEMETRY_STATE"
  assert_equals_helper 'db' "$LINENO" "${XDG_DATA_HOME}/.kw/kw.db" "$TELEMETRY_DB"
}

function test_paths_default_kworkflow_name_is_kw()
{
  unset -v KWORKFLOW
  telemetry_paths
  assert_equals_helper 'config' "$LINENO" "${XDG_CONFIG_HOME}/kw/telemetry.config" "$TELEMETRY_CONFIG"
  assert_equals_helper 'state' "$LINENO" "${XDG_STATE_HOME}/kw/telemetry.state" "$TELEMETRY_STATE"
  assert_equals_helper 'db' "$LINENO" "${XDG_DATA_HOME}/kw/kw.db" "$TELEMETRY_DB"
}

function test_paths_fall_back_to_home_when_xdg_is_unset()
{
  unset -v XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
  telemetry_paths
  assert_equals_helper 'config' "$LINENO" "${HOME}/.config/kw/telemetry.config" "$TELEMETRY_CONFIG"
  assert_equals_helper 'state' "$LINENO" "${HOME}/.local/state/kw/telemetry.state" "$TELEMETRY_STATE"
  assert_equals_helper 'db' "$LINENO" "${HOME}/.local/share/kw/kw.db" "$TELEMETRY_DB"
}

function test_paths_honour_kw_variables_over_xdg()
{
  export KW_TELE_CONFIG="${TD}/elsewhere/t.config" KW_STATE_DIR="${TD}/st" KW_DATA_DIR="${TD}/da"
  telemetry_paths
  assert_equals_helper 'config' "$LINENO" "${TD}/elsewhere/t.config" "$TELEMETRY_CONFIG"
  assert_equals_helper 'state' "$LINENO" "${TD}/st/telemetry.state" "$TELEMETRY_STATE"
  assert_equals_helper 'db' "$LINENO" "${TD}/da/kw.db" "$TELEMETRY_DB"
}

function test_paths_ignore_kw_etc_dir()
{
  export KW_ETC_DIR="${TD}/etc"
  telemetry_paths
  assert_equals_helper 'config' "$LINENO" "${XDG_CONFIG_HOME}/kw/telemetry.config" "$TELEMETRY_CONFIG"
}

function test_paths_do_not_fork()
{
  tele_count_forks telemetry_paths
  if ((TELE_FORKS < 0)); then
    startSkipping
    return
  fi
  assert_equals_helper 'forks' "$LINENO" 0 "$TELE_FORKS"
}

# ------------------------------------------------------ telemetry_ensure_schema

# Runs the guard and checks that it prints nothing on either stream.
function ensure_schema_quiet()
{
  telemetry_paths
  telemetry_ensure_schema < /dev/null > "${TD}/schema.out" 2> "${TD}/schema.err"
  SCHEMA_RC="$?"
  assertEquals "($1) stdout" '' "$(< "${TD}/schema.out")"
  assertEquals "($1) stderr" '' "$(< "${TD}/schema.err")"
}

function index_is_partial_on_id()
{
  local partial
  local column
  local sql

  partial="$(sqlite3 "$TELE_DB" "SELECT partial FROM pragma_index_list('event') WHERE name = 'event_unsent_idx'")"
  column="$(sqlite3 "$TELE_DB" "SELECT group_concat(name) FROM pragma_index_info('event_unsent_idx')")"
  sql="$(sqlite3 "$TELE_DB" "SELECT sql FROM sqlite_master WHERE name = 'event_unsent_idx'")"
  [[ "$partial" == 1 && "$column" == 'id' && "$sql" == *'sent_at IS NULL'* ]]
}

function test_ensure_schema_adds_column_and_partial_index()
{
  tele_make_db legacy
  ensure_schema_quiet "$LINENO"
  assertEquals "($LINENO)" 0 "$SCHEMA_RC"
  tele_db_has_sent_at
  assertEquals "($LINENO) sent_at column" 0 "$?"
  index_is_partial_on_id
  assertEquals "($LINENO) partial index event_unsent_idx(id) WHERE sent_at IS NULL" 0 "$?"
}

function test_ensure_schema_keeps_existing_rows_pending()
{
  tele_make_db legacy
  sqlite3 "$TELE_DB" "INSERT INTO event (date, time) VALUES ('2026-01-01', '10:00:00'), ('2026-01-02', NULL)"
  ensure_schema_quiet "$LINENO"
  assert_equals_helper 'rows' "$LINENO" '2' "$(sqlite3 "$TELE_DB" 'SELECT COUNT(*) FROM event')"
  assert_equals_helper 'all pending' "$LINENO" '2' "$(sqlite3 "$TELE_DB" 'SELECT COUNT(*) FROM event WHERE sent_at IS NULL')"
}

function test_ensure_schema_adds_only_the_index_on_a_current_db()
{
  tele_make_db
  ensure_schema_quiet "$LINENO"
  assertEquals "($LINENO)" 0 "$SCHEMA_RC"
  index_is_partial_on_id
  assertEquals "($LINENO) partial index" 0 "$?"
}

function test_ensure_schema_is_idempotent()
{
  local before
  local after

  tele_make_db legacy
  ensure_schema_quiet "$LINENO"
  before="$(sqlite3 "$TELE_DB" 'PRAGMA schema_version')"
  ensure_schema_quiet "$LINENO"
  after="$(sqlite3 "$TELE_DB" 'PRAGMA schema_version')"
  assertEquals "($LINENO) second run" 0 "$SCHEMA_RC"
  assert_equals_helper 'schema untouched by the second run' "$LINENO" "$before" "$after"
  index_is_partial_on_id
  assertEquals "($LINENO)" 0 "$?"
}

function test_ensure_schema_returns_2_without_a_db_and_creates_nothing()
{
  ensure_schema_quiet "$LINENO"
  assertEquals "($LINENO)" 2 "$SCHEMA_RC"
  assertFalse "($LINENO) must not create the DB" "[[ -e ${TELE_DB} ]]"
}

function test_ensure_schema_tolerates_a_concurrent_alter()
{
  tele_make_db legacy
  tele_install_sqlite_race 1
  ensure_schema_quiet "$LINENO"
  assertEquals "($LINENO) column appeared meanwhile" 0 "$SCHEMA_RC"
  tele_db_has_sent_at
  assertEquals "($LINENO)" 0 "$?"
  index_is_partial_on_id
  assertEquals "($LINENO) index still created" 0 "$?"
}

function test_ensure_schema_fails_quietly_when_the_column_stays_missing()
{
  tele_make_db legacy
  tele_install_sqlite_race 0
  ensure_schema_quiet "$LINENO"
  assertNotEquals "($LINENO) must fail" 0 "$SCHEMA_RC"
  assertNotEquals "($LINENO) 2 means no DB" 2 "$SCHEMA_RC"
}

function test_ensure_schema_stays_silent_on_a_file_that_is_not_a_database()
{
  printf 'this is not sqlite\n' > "$TELE_DB"
  ensure_schema_quiet "$LINENO"
  assertNotEquals "($LINENO)" 0 "$SCHEMA_RC"
}

# ---------------------------------------------------------------- telemetry_gate

function test_gate_early_actions_never_spawn_or_prompt()
{
  local action

  tele_consent_yes
  for action in '' telemetry help h --help -h man version --version -v; do
    tele_reset_spawn
    run_gate "$action" "$LINENO"
    assert_gate_outcome "$LINENO" 'not spawned' "action '${action}'"
    assertEquals "($LINENO) action '${action}' stderr" '' "$GATE_ERR"
  done
}

function test_gate_control_a_regular_action_spawns_in_the_same_setup()
{
  tele_consent_yes
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'regular action with due upload'
}

function test_gate_early_actions_do_not_prompt_on_a_terminal()
{
  local action

  tele_write_config 'telemetry_consent=ask'
  for action in help version telemetry; do
    tele_run_pty '3\n' "telemetry_gate ${action}"
    assertEquals "($LINENO) gate ran and returned 0" 0 "$TELE_PTY_RC"
    assert_lacks "$LINENO" "action ${action}" "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  done
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"
}

function test_gate_does_nothing_when_kw_tele_is_not_on_path()
{
  tele_consent_yes
  tele_limited_path kw_tele
  GATE_PATH="$TELE_LIMITED_PATH" run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'no kw_tele'
  assertFalse "($LINENO) spawn file" "[[ -e ${TELE_STATE_DIR}/telemetry.spawn ]]"
}

function test_gate_does_nothing_when_consent_is_no()
{
  tele_write_config 'telemetry_consent=no' "endpoint=${TELE_ENDPOINT}"
  run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'consent=no'
  assertEquals "($LINENO) no kw_tele call at all" '' "$(tele_calls)"
}

function test_gate_does_not_prompt_when_consent_is_no_on_a_terminal()
{
  tele_write_config 'telemetry_consent=no'
  tele_run_pty '1\n' 'telemetry_gate build'
  assertEquals "($LINENO) gate ran and returned 0" 0 "$TELE_PTY_RC"
  assert_lacks "$LINENO" 'prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assertEquals "($LINENO)" '' "$(tele_calls)"
}

function test_gate_consent_ask_without_a_terminal_neither_prompts_nor_writes()
{
  local before

  tele_write_config 'telemetry_consent=ask' "endpoint=${TELE_ENDPOINT}"
  before="$(< "$TELE_CONFIG")"
  run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_equals_helper 'config unchanged' "$LINENO" "$before" "$(< "$TELE_CONFIG")"
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"
  assert_gate_outcome "$LINENO" 'not spawned' 'ask'
}

function test_gate_missing_config_counts_as_ask_and_writes_nothing()
{
  rm -f "$TELE_CONFIG"
  run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assertFalse "($LINENO) config created" "[[ -e ${TELE_CONFIG} ]]"
  assertEquals "($LINENO)" '' "$(tele_calls)"
}

function test_gate_unknown_consent_value_counts_as_ask()
{
  tele_write_config 'telemetry_consent=YES' "instance_id=${TELE_INSTANCE_ID}" "consented_endpoint=${TELE_DEFAULT_ENDPOINT}"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'values are case-sensitive'
  assertEquals "($LINENO)" '' "$(tele_calls)"
}

function test_gate_consent_ask_with_a_terminal_prompts_and_does_not_upload()
{
  tele_write_config 'telemetry_consent=ask'
  tele_stub_set stdout.info $'pending_events=2\npending_since=2026-01-05'
  tele_run_pty '3\n' 'telemetry_gate build'
  assert_has "$LINENO" 'prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_has "$LINENO" 'answer 3' "$(tele_calls)" 'consent --set no'
  assert_lacks "$LINENO" 'nothing uploads on the same command' "$(tele_calls)" 'upload'
  assertFalse "($LINENO) spawn file" "[[ -e ${TELE_STATE_DIR}/telemetry.spawn ]]"
}

function test_gate_effective_consent_needs_a_non_empty_instance_id()
{
  tele_write_config 'telemetry_consent=yes' 'instance_id=' "consented_endpoint=${TELE_DEFAULT_ENDPOINT}"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'empty instance_id'
}

function test_gate_effective_consent_fails_on_endpoint_mismatch()
{
  local label
  local consented
  local endpoint

  while IFS='|' read -r label consented endpoint; do
    tele_write_config 'telemetry_consent=yes' "instance_id=${TELE_INSTANCE_ID}" \
      "consented_endpoint=${consented}" "endpoint=${endpoint}"
    tele_reset_spawn
    run_gate build "$LINENO"
    assert_gate_outcome "$LINENO" 'not spawned' "$label"
  done << 'EOF'
edited endpoint|http://a.test/v1/logs|http://b.test/v1/logs
trailing slash|http://a.test/v1/logs|http://a.test/v1/logs/
empty consented_endpoint||http://a.test/v1/logs
case differs|http://A.test/v1/logs|http://a.test/v1/logs
EOF
}

function test_gate_endpoint_mismatch_prompts_again_on_a_terminal()
{
  tele_write_config 'telemetry_consent=yes' "instance_id=${TELE_INSTANCE_ID}" \
    'consented_endpoint=http://old.test/v1/logs' 'endpoint=http://new.test/v1/logs'
  tele_run_pty '\n' 'telemetry_gate build'
  assert_has "$LINENO" 'prompt' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_has "$LINENO" 'new endpoint shown' "$TELE_PTY_OUT" 'http://new.test/v1/logs'
}

function test_gate_consent_is_effective_with_the_default_endpoint_when_unset()
{
  tele_write_config 'telemetry_consent=yes' "instance_id=${TELE_INSTANCE_ID}" "consented_endpoint=${TELE_DEFAULT_ENDPOINT}"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'default endpoint'
}

function test_gate_reads_a_config_with_crlf_line_endings()
{
  printf 'telemetry_consent=yes\r\ninstance_id=%s\r\nconsented_endpoint=%s\r\nendpoint=%s\r\n' \
    "$TELE_INSTANCE_ID" "$TELE_ENDPOINT" "$TELE_ENDPOINT" > "$TELE_CONFIG"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'CRLF'
}

function test_gate_spawns_when_time_is_due()
{
  tele_consent_yes
  tele_write_state 0 $((TELE_NOW - 86400)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'time_due at exactly upload_interval'
}

function test_gate_does_not_spawn_just_before_time_is_due()
{
  tele_consent_yes
  tele_make_db
  tele_write_state 0 $((TELE_NOW - 86399)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'one second before time_due'
}

function test_gate_spacing_after_a_success_is_upload_backoff()
{
  tele_consent_yes
  tele_write_state $((TELE_NOW - 3599)) 0 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'attempt 3599 s ago'
  tele_reset_spawn
  tele_write_state $((TELE_NOW - 3600)) 0 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'attempt exactly upload_backoff ago'
}

function test_gate_spacing_doubles_with_each_failure_and_is_capped()
{
  local failures
  local gap
  local attempt
  local expected

  tele_consent_yes
  while IFS=' ' read -r failures gap; do
    for attempt in $((gap - 1)) "$gap"; do
      tele_reset_spawn
      tele_write_state $((TELE_NOW - attempt)) 0 "$failures"
      run_gate build "$LINENO"
      expected='not spawned'
      ((attempt >= gap)) && expected='spawned'
      assert_gate_outcome "$LINENO" "$expected" "k=${failures} gap=${gap} attempt ${attempt} s ago"
    done
  done << 'EOF'
1 3600
2 7200
3 14400
5 57600
6 86400
30 86400
EOF
}

function test_gate_failure_gap_is_capped_by_the_larger_of_interval_and_backoff()
{
  tele_consent_yes 'upload_backoff=100000' 'upload_interval=50'
  tele_write_state $((TELE_NOW - 100000)) 0 3
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'gap is min(400000, max(50, 100000))'
  tele_reset_spawn
  tele_write_state $((TELE_NOW - 99999)) 0 3
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'one second short of the capped gap'
}

function test_gate_honours_upload_backoff_from_the_config()
{
  tele_consent_yes 'upload_backoff=60'
  tele_write_state $((TELE_NOW - 59)) 0 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' '59 s'
  tele_reset_spawn
  tele_write_state $((TELE_NOW - 60)) 0 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned '60 s'
}

function test_gate_honours_upload_interval_from_the_config()
{
  tele_consent_yes 'upload_interval=100'
  tele_make_db
  tele_write_state 0 $((TELE_NOW - 99)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' '99 s since success'
  tele_reset_spawn
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned '100 s since success'
}

function test_gate_spawn_file_limits_spawns_to_one_per_backoff()
{
  tele_consent_yes
  printf '%s\n' $((TELE_NOW - 3599)) > "${TELE_STATE_DIR}/telemetry.spawn"
  run_gate build "$LINENO"
  assertEquals "($LINENO) no upload" 0 "$(tele_upload_calls)"
  assertEquals "($LINENO) spawn file kept" $((TELE_NOW - 3599)) "$(< "${TELE_STATE_DIR}/telemetry.spawn")"
  printf '%s\n' $((TELE_NOW - 3600)) > "${TELE_STATE_DIR}/telemetry.spawn"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'spawned exactly upload_backoff ago'
}

function test_gate_second_call_inside_the_backoff_does_not_spawn_even_if_the_uploader_wrote_no_state()
{
  tele_consent_yes
  tele_stub_set exit 1
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'first call'
  assertFalse "($LINENO) stub must not have written state" "[[ -e ${TELE_STATE_DIR}/telemetry.state ]]"
  KW_TELE_NOW=$((TELE_NOW + 10)) run_gate build "$LINENO"
  assertEquals "($LINENO) spawn file still holds the first spawn" "$TELE_NOW" "$(< "${TELE_STATE_DIR}/telemetry.spawn")"
  assertEquals "($LINENO) one upload only" 1 "$(tele_upload_calls)"
  export KW_TELE_NOW=$((TELE_NOW + 3600))
  run_gate build "$LINENO"
  assertEquals "($LINENO) spawn file refreshed after the backoff" $((TELE_NOW + 3600)) "$(< "${TELE_STATE_DIR}/telemetry.spawn")"
}

function test_gate_garbage_in_the_spawn_file_counts_as_zero()
{
  tele_consent_yes
  printf '%s\n' '08' > "${TELE_STATE_DIR}/telemetry.spawn"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'invalid integer falls back to 0'
  assertEquals "($LINENO)" "$TELE_NOW" "$(< "${TELE_STATE_DIR}/telemetry.spawn")"
}

function test_gate_spawn_file_holds_now_and_a_newline_only()
{
  local content=''

  tele_consent_yes
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  IFS= read -r -d '' content < "${TELE_STATE_DIR}/telemetry.spawn"
  assert_equals_helper 'bytes' "$LINENO" "${TELE_NOW}"$'\n' "$content"
}

function test_gate_below_batch_does_not_spawn()
{
  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_add_events 4
  tele_add_events 3 -1
  tele_add_events 3 1700000000
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' '4 pending of 5; excluded and sent rows do not count'
}

function test_gate_at_batch_spawns()
{
  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_add_events 5
  tele_add_events 3 -1
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned '5 pending of 5'
}

function test_gate_above_batch_spawns_and_the_count_is_capped()
{
  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_add_events 40
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned '40 pending'
}

function test_gate_size_due_still_needs_spacing()
{
  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_add_events 9
  tele_write_state $((TELE_NOW - 100)) $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'spacing not ok'
}

function test_gate_count_query_is_the_capped_readonly_one()
{
  local args

  tele_consent_yes 'batch_size=7'
  tele_make_db
  tele_install_fake_count 0
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  args=$'\n'"$(< "$TELE_SQLITE_RECORD")"$'\n'
  assert_has "$LINENO" 'readonly' "$args" $'\n-readonly\n'
  assert_has "$LINENO" 'init' "$args" $'\n-init\n/dev/null\n'
  assert_has "$LINENO" 'batch' "$args" $'\n-batch\n'
  assert_has "$LINENO" 'noheader' "$args" $'\n-noheader\n'
  assert_has "$LINENO" 'timeout' "$args" $'\n.timeout 100\n'
  assert_has "$LINENO" 'db' "$args" $'\n'"${TELE_DB}"$'\n'
  assert_has "$LINENO" 'sql' "$args" $'\nSELECT COUNT(*) FROM (SELECT 1 FROM event WHERE sent_at IS NULL LIMIT 7)\n'
}

function test_gate_count_that_fails_or_is_not_an_integer_does_not_spawn()
{
  local label
  local value
  local code

  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_write_state 0 $((TELE_NOW - 100)) 0
  while IFS='|' read -r label value code; do
    tele_reset_spawn
    tele_install_fake_count "$value" "$code"
    run_gate build "$LINENO"
    assert_gate_outcome "$LINENO" 'not spawned' "$label"
  done << 'EOF'
non-integer|many|0
empty output||0
failure with a big number|99|1
negative|-1|0
EOF
}

function test_gate_count_failure_on_a_db_without_sent_at_is_silent()
{
  tele_consent_yes
  tele_make_db legacy
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assertEquals "($LINENO) nothing on stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'no sent_at column'
  tele_db_has_sent_at
  assertEquals "($LINENO) the gate must not migrate on the COUNT path" 1 "$?"
}

function test_gate_missing_db_on_the_count_path_is_silent_and_creates_nothing()
{
  tele_consent_yes
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assertEquals "($LINENO) nothing on stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'no DB'
  assertFalse "($LINENO) DB created" "[[ -e ${TELE_DB} ]]"
}

function test_gate_ignores_a_sqliterc_in_home()
{
  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_add_events 1
  printf '%s\n' '.print NOISE' > "${HOME}/.sqliterc"
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assertEquals "($LINENO)" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'rc file output must not be read as the count'
}

function test_gate_integer_grammar_for_config_values()
{
  local label
  local setting

  while IFS='|' read -r label setting; do
    tele_reset_spawn
    tele_consent_yes "$setting"
    tele_write_state $((TELE_NOW - 2000)) 0 0
    run_gate build "$LINENO"
    assert_gate_outcome "$LINENO" 'not spawned' "${label}: falls back to the 3600 s default"
  done << 'EOF'
leading zero|upload_backoff=08
negative|upload_backoff=-1
plus sign|upload_backoff=+5
19 digits|upload_backoff=1234567890123456789
zero|upload_backoff=0
above range|upload_backoff=31536001
not a number|upload_backoff=soon
EOF
}

function test_gate_valid_integers_are_taken_as_decimal()
{
  tele_consent_yes 'upload_backoff = 100 '
  tele_write_state $((TELE_NOW - 2000)) 0 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'whitespace around the integer is trimmed'
  tele_reset_spawn
  tele_consent_yes 'upload_backoff=31536000'
  tele_write_state $((TELE_NOW - 31535999)) 0 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'upper bound of the range is valid'
}

function test_gate_upload_interval_with_a_leading_zero_falls_back_to_the_default()
{
  tele_consent_yes 'upload_interval=08'
  tele_make_db
  tele_write_state 0 $((TELE_NOW - 50000)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'default 86400, not 8'
}

function test_gate_batch_size_zero_and_invalid_values_fall_back_to_500()
{
  local setting

  tele_make_db
  tele_add_events 100
  tele_write_state 0 $((TELE_NOW - 100)) 0
  for setting in batch_size=0 batch_size=08 batch_size=5001 batch_size=-3 batch_size=lots; do
    tele_reset_spawn
    tele_consent_yes "$setting"
    run_gate build "$LINENO"
    assert_gate_outcome "$LINENO" 'not spawned' "${setting}: 100 pending is below the default 500"
  done
}

function test_gate_batch_size_upper_bound_is_valid()
{
  tele_consent_yes 'batch_size=5000'
  tele_make_db
  tele_add_events 4999
  tele_write_state 0 $((TELE_NOW - 100)) 0
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' '4999 of 5000'
  tele_add_events 1
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned '5000 of 5000'
}

function test_gate_integer_grammar_for_state_values()
{
  tele_consent_yes
  printf 'last_attempt_at=%s\nlast_success_at=0\nconsecutive_failures=08\nlast_status=\n' \
    $((TELE_NOW - 4000)) > "${TELE_STATE_DIR}/telemetry.state"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'consecutive_failures=08 reads as 0, gap 3600'
}

function test_gate_state_file_with_crlf_and_no_final_newline()
{
  tele_consent_yes
  printf 'last_attempt_at=%s\r\nlast_success_at=0\r\nconsecutive_failures=0' $((TELE_NOW - 100)) > "${TELE_STATE_DIR}/telemetry.state"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" 'not spawned' 'attempt 100 s ago'
}

function test_gate_spawn_passes_exact_environment_to_kw_tele()
{
  tele_consent_yes
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assert_equals_helper 'argv' "$LINENO" 'upload' "$(tele_calls)"
  assert_equals_helper 'argc' "$LINENO" '1' "$(tele_call_field upload argc)"
  assert_equals_helper 'KW_TELE_CONFIG' "$LINENO" "$TELE_CONFIG" "$(tele_call_field upload KW_TELE_CONFIG)"
  assert_equals_helper 'KW_DATA_DIR' "$LINENO" "$TELE_DATA_DIR" "$(tele_call_field upload KW_DATA_DIR)"
  assert_equals_helper 'KW_STATE_DIR' "$LINENO" "$TELE_STATE_DIR" "$(tele_call_field upload KW_STATE_DIR)"
  assert_equals_helper 'KW_VERSION' "$LINENO" "$(head -n 1 ./src/VERSION)" "$(tele_call_field upload KW_VERSION)"
}

function test_gate_spawn_passes_the_callers_explicit_paths()
{
  export KW_TELE_CONFIG="${TD}/cfg/custom.config" KW_STATE_DIR="${TD}/custom_state" KW_DATA_DIR="${TD}/custom_data"
  mkdir -p "${TD}/cfg" "$KW_STATE_DIR" "$KW_DATA_DIR"
  printf 'telemetry_consent=yes\ninstance_id=%s\nconsented_endpoint=%s\nendpoint=%s\n' \
    "$TELE_INSTANCE_ID" "$TELE_ENDPOINT" "$TELE_ENDPOINT" > "$KW_TELE_CONFIG"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assert_equals_helper 'KW_TELE_CONFIG' "$LINENO" "$KW_TELE_CONFIG" "$(tele_call_field upload KW_TELE_CONFIG)"
  assert_equals_helper 'KW_DATA_DIR' "$LINENO" "$KW_DATA_DIR" "$(tele_call_field upload KW_DATA_DIR)"
  assert_equals_helper 'KW_STATE_DIR' "$LINENO" "$KW_STATE_DIR" "$(tele_call_field upload KW_STATE_DIR)"
  assertTrue "($LINENO) spawn file in the given state dir" "[[ -e ${KW_STATE_DIR}/telemetry.spawn ]]"
}

function test_gate_kw_version_comes_from_the_first_line_of_the_lib_dir_version_file()
{
  mkdir -p "${TD}/lib_a" "${TD}/lib_b"
  printf '1.2.3-test\nBranch: x\n' > "${TD}/lib_a/VERSION"
  export KW_LIB_DIR="${TD}/lib_a"
  tele_consent_yes
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assert_equals_helper 'first line only' "$LINENO" '1.2.3-test' "$(tele_call_field upload KW_VERSION)"
  tele_reset_spawn
  export KW_LIB_DIR="${TD}/lib_b"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assert_equals_helper 'missing VERSION' "$LINENO" 'unknown' "$(tele_call_field upload KW_VERSION)"
}

function test_gate_spawns_a_detached_session_with_a_timeout_and_no_stdio()
{
  local my_sid
  local -a stat_fields

  tele_consent_yes
  read -r -a stat_fields < "/proc/$$/stat"
  my_sid="${stat_fields[5]}"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assertNotEquals "($LINENO) new session" "$my_sid" "$(tele_call_field upload sid)"
  assert_has "$LINENO" 'wrapped in timeout 90' "$(tele_call_field upload parent)" 'timeout 90 kw_tele upload'
  assert_equals_helper 'stdin' "$LINENO" '/dev/null' "$(tele_call_field upload stdin)"
  assert_equals_helper 'stdout' "$LINENO" '/dev/null' "$(tele_call_field upload stdout)"
  assert_equals_helper 'stderr' "$LINENO" '/dev/null' "$(tele_call_field upload stderr)"
}

function test_gate_never_waits_for_the_uploader_nor_keeps_its_stdout_open()
{
  local start
  local elapsed
  local out

  tele_consent_yes
  tele_stub_set hang 2
  start=${EPOCHREALTIME//[.,]/}
  out="$(telemetry_gate build < /dev/null 2>&1)"
  elapsed=$((${EPOCHREALTIME//[.,]/} - start))
  assertEquals "($LINENO) output" '' "$out"
  assertTrue "($LINENO) gate took ${elapsed} us" "((elapsed < 1000000))"
}

function test_gate_spawn_migrates_the_schema_once()
{
  tele_consent_yes
  tele_make_db legacy
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  tele_db_has_sent_at
  assertEquals "($LINENO) sent_at added before the uploader starts" 0 "$?"
  assert_equals_helper 'index' "$LINENO" 'event_unsent_idx' "$(sqlite3 "$TELE_DB" "SELECT name FROM sqlite_master WHERE name = 'event_unsent_idx'")"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
}

function test_gate_spawns_even_when_there_is_no_db_if_time_is_due()
{
  tele_consent_yes
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due, no DB: kw_tele reports error:nodb itself'
  assertFalse "($LINENO) no DB created by the gate" "[[ -e ${TELE_DB} ]]"
}

function test_gate_missing_state_dir_prevents_the_spawn()
{
  tele_consent_yes
  rmdir "$TELE_STATE_DIR"
  run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'state dir missing'
  assertFalse "($LINENO) the gate must not create the state dir" "[[ -e ${TELE_STATE_DIR} ]]"
}

function test_gate_unwritable_state_dir_prevents_the_spawn()
{
  if [[ "$EUID" == 0 ]]; then
    startSkipping
    return
  fi
  tele_consent_yes
  chmod 555 "$TELE_STATE_DIR"
  run_gate build "$LINENO"
  chmod 755 "$TELE_STATE_DIR"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'state dir read-only'
}

function test_gate_state_dir_that_is_a_file_prevents_the_spawn()
{
  tele_consent_yes
  rmdir "$TELE_STATE_DIR"
  : > "$TELE_STATE_DIR"
  run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'state dir is a file'
}

function test_gate_without_setsid_does_not_spawn()
{
  tele_consent_yes
  tele_limited_path setsid
  GATE_PATH="$TELE_LIMITED_PATH" run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'no setsid'
  assertFalse "($LINENO) spawn file" "[[ -e ${TELE_STATE_DIR}/telemetry.spawn ]]"
}

function test_gate_without_timeout_does_not_spawn()
{
  tele_consent_yes
  tele_limited_path timeout
  GATE_PATH="$TELE_LIMITED_PATH" run_gate build "$LINENO"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'no timeout'
  assertFalse "($LINENO) spawn file" "[[ -e ${TELE_STATE_DIR}/telemetry.spawn ]]"
}

function test_gate_control_limited_path_with_every_tool_spawns()
{
  tele_consent_yes
  tele_limited_path
  GATE_PATH="$TELE_LIMITED_PATH" run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'limited PATH holding every needed tool'
}

function test_gate_ignores_kw_tele_now_without_the_test_flag()
{
  local spawned_at

  tele_consent_yes
  unset -v KW_TELE_TEST
  export KW_TELE_NOW=100
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'real clock used: time_due'
  spawned_at="$(< "${TELE_STATE_DIR}/telemetry.spawn")"
  assertTrue "($LINENO) spawn file has the real time, got ${spawned_at}" "((spawned_at > 1700000000))"
}

function test_gate_writes_only_the_spawn_file()
{
  local config_before
  local state_before
  local files

  tele_consent_yes
  tele_write_state 5 6 1
  config_before="$(< "$TELE_CONFIG")"
  state_before="$(< "${TELE_STATE_DIR}/telemetry.state")"
  KW_TELE_NOW=$((TELE_NOW + 99999)) run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assert_equals_helper 'config' "$LINENO" "$config_before" "$(< "$TELE_CONFIG")"
  assert_equals_helper 'state' "$LINENO" "$state_before" "$(< "${TELE_STATE_DIR}/telemetry.state")"
  files="$(cd "$TELE_STATE_DIR" && printf '%s ' *)"
  assert_equals_helper 'files in state dir' "$LINENO" 'telemetry.spawn telemetry.state ' "$files"
}

function test_gate_does_not_leak_variables_into_the_caller_shell()
{
  local before
  local after
  local name
  local leaked=''

  tele_consent_yes
  tele_make_db legacy
  before="$(compgen -v | sort)"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  after="$(compgen -v | sort)"
  for name in $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after")); do
    case "$name" in
      TELEMETRY_* | GATE_* | before | after | name | leaked | REPLY) continue ;;
    esac
    leaked+=" ${name}"
  done
  assertEquals "($LINENO) new variables" '' "$leaked"
  assertFalse "($LINENO) KW_VERSION" '[[ -v KW_VERSION ]]'
  assertFalse "($LINENO) KW_DATA_DIR" '[[ -v KW_DATA_DIR ]]'
  assertFalse "($LINENO) KW_STATE_DIR" '[[ -v KW_STATE_DIR ]]'
  assertFalse "($LINENO) KW_TELE_CONFIG" '[[ -v KW_TELE_CONFIG ]]'
}

function test_gate_does_not_export_variables_the_caller_only_set()
{
  KW_DATA_DIR="$TELE_DATA_DIR"
  KW_STATE_DIR="$TELE_STATE_DIR"
  tele_consent_yes
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  is_exported KW_DATA_DIR
  assertEquals "($LINENO) KW_DATA_DIR stays unexported" 1 "$?"
  is_exported KW_STATE_DIR
  assertEquals "($LINENO) KW_STATE_DIR stays unexported" 1 "$?"
  is_exported KW_VERSION
  assertEquals "($LINENO) KW_VERSION not exported" 1 "$?"
  is_exported KW_TELE_CONFIG
  assertEquals "($LINENO) KW_TELE_CONFIG not exported" 1 "$?"
}

function test_gate_returns_0_on_unreadable_or_odd_config()
{
  tele_write_config 'telemetry_consent=yes'
  chmod 000 "$TELE_CONFIG"
  run_gate build "$LINENO"
  chmod 644 "$TELE_CONFIG"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  rm -f "$TELE_CONFIG"
  mkdir "$TELE_CONFIG"
  run_gate build "$LINENO"
  assertEquals "($LINENO) config is a directory, stderr" '' "$GATE_ERR"
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"
}

function test_gate_under_set_u_does_not_fail_on_unset_variables()
{
  tele_consent_yes
  unset -v KW_DATA_DIR KW_STATE_DIR KW_TELE_CONFIG KWORKFLOW
  set -u
  run_gate build "$LINENO"
  set +u
  assert_gate_outcome "$LINENO" spawned 'due'
}

function test_gate_fork_budget_is_zero_before_the_count()
{
  tele_make_db
  tele_write_config 'telemetry_consent=no'
  tele_count_forks telemetry_gate build
  if ((TELE_FORKS < 0)); then
    startSkipping
    return
  fi
  assert_equals_helper 'consent=no' "$LINENO" 0 "$TELE_FORKS"

  tele_consent_yes
  tele_count_forks telemetry_gate help
  assert_equals_helper 'early action' "$LINENO" 0 "$TELE_FORKS"

  tele_write_state $((TELE_NOW - 10)) $((TELE_NOW - 10)) 0
  tele_count_forks telemetry_gate build
  assert_equals_helper 'spacing not ok' "$LINENO" 0 "$TELE_FORKS"

  tele_write_config 'telemetry_consent=ask'
  tele_count_forks telemetry_gate build
  assert_equals_helper 'ask without terminal' "$LINENO" 0 "$TELE_FORKS"
}

function gate_with_limited_path()
{
  PATH="$TELE_LIMITED_PATH" telemetry_gate build
}

function test_gate_fork_budget_is_zero_without_kw_tele()
{
  tele_consent_yes
  tele_limited_path kw_tele
  tele_count_forks gate_with_limited_path
  if ((TELE_FORKS < 0)); then
    startSkipping
    return
  fi
  assert_equals_helper 'no kw_tele' "$LINENO" 0 "$TELE_FORKS"
}

function test_gate_fork_budget_is_one_on_the_count_path()
{
  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_install_fake_count 0
  tele_write_state 0 $((TELE_NOW - 100)) 0
  tele_count_forks telemetry_gate build
  if ((TELE_FORKS < 0)); then
    startSkipping
    return
  fi
  assertTrue "($LINENO) the COUNT query must have run" "[[ -s ${TELE_SQLITE_RECORD} ]]"
  assert_equals_helper 'below batch: one COUNT fork' "$LINENO" 1 "$TELE_FORKS"
  assertEquals "($LINENO) still no spawn" 0 "$(tele_upload_calls)"
}

# ------------------------------------------------------ telemetry_prompt_consent

function calls_starting_with()
{
  local call

  while IFS= read -r call; do
    [[ "$call" == "$1"* ]] && printf '%s\n' "$call"
  done < <(tele_calls)
}

function run_prompt()
{
  tele_run_pty "$1" 'telemetry_paths; telemetry_prompt_consent'
}

function count_choice_lines()
{
  local line
  local count=0

  while IFS= read -r line; do
    [[ "$line" == *'Choice [3]:'* ]] && ((count++))
  done <<< "$TELE_PTY_OUT"
  printf '%s' "$count"
}

function test_prompt_answer_1_sets_yes_with_history()
{
  tele_stub_set stdout.info $'pending_events=42\npending_since=2026-01-05'
  run_prompt '1\n'
  assertEquals "($LINENO) return" 0 "$TELE_PTY_RC"
  assert_equals_helper 'consent calls' "$LINENO" 'consent --set yes --include-history' "$(calls_starting_with consent)"
}

function test_prompt_answer_2_sets_yes_only_from_now_on()
{
  tele_stub_set stdout.info $'pending_events=42\npending_since=2026-01-05'
  run_prompt '2\n'
  assertEquals "($LINENO) return" 0 "$TELE_PTY_RC"
  assert_equals_helper 'consent calls' "$LINENO" 'consent --set yes' "$(calls_starting_with consent)"
}

function test_prompt_answer_3_sets_no()
{
  run_prompt '3\n'
  assertEquals "($LINENO) return" 0 "$TELE_PTY_RC"
  assert_equals_helper 'consent calls' "$LINENO" 'consent --set no' "$(calls_starting_with consent)"
}

function test_prompt_enter_defaults_to_3()
{
  run_prompt '\n'
  assertEquals "($LINENO) return" 0 "$TELE_PTY_RC"
  assert_equals_helper 'consent calls' "$LINENO" 'consent --set no' "$(calls_starting_with consent)"
}

function test_prompt_trims_whitespace_around_the_answer()
{
  run_prompt '  1 \n'
  assert_equals_helper 'consent calls' "$LINENO" 'consent --set yes --include-history' "$(calls_starting_with consent)"
  tele_reset_spawn
  run_prompt '\t2\t\n'
  assert_equals_helper 'consent calls' "$LINENO" 'consent --set yes' "$(calls_starting_with consent)"
}

function test_prompt_reasks_on_invalid_input_and_accepts_a_later_answer()
{
  run_prompt 'x\n4\n2\n'
  assertEquals "($LINENO) return" 0 "$TELE_PTY_RC"
  assert_equals_helper 'consent calls' "$LINENO" 'consent --set yes' "$(calls_starting_with consent)"
  assert_equals_helper 'asked three times' "$LINENO" 3 "$(count_choice_lines)"
}

function test_prompt_gives_up_after_three_invalid_answers_and_writes_nothing()
{
  run_prompt 'x\ny\nz\n2\n'
  assertEquals "($LINENO) return" 1 "$TELE_PTY_RC"
  assertEquals "($LINENO) no consent call" '' "$(calls_starting_with consent)"
  assert_equals_helper 'asked three times' "$LINENO" 3 "$(count_choice_lines)"
}

function test_prompt_numbers_outside_1_to_3_and_words_are_invalid()
{
  run_prompt '0\n11\nyes\n'
  assertEquals "($LINENO) return" 1 "$TELE_PTY_RC"
  assertEquals "($LINENO) no consent call" '' "$(calls_starting_with consent)"
}

function test_prompt_eof_writes_nothing()
{
  run_prompt ''
  assertEquals "($LINENO) return" 1 "$TELE_PTY_RC"
  assertEquals "($LINENO) no consent call" '' "$(calls_starting_with consent)"
}

function test_prompt_eof_after_an_invalid_answer_writes_nothing()
{
  run_prompt 'x\n'
  assertEquals "($LINENO) return" 1 "$TELE_PTY_RC"
  assertEquals "($LINENO) no consent call" '' "$(calls_starting_with consent)"
}

function test_prompt_without_stdin_terminal_does_nothing()
{
  telemetry_paths
  telemetry_prompt_consent < /dev/null > "${TD}/out" 2> "${TD}/err"
  assertEquals "($LINENO) return" 1 "$?"
  assertEquals "($LINENO) stdout" '' "$(< "${TD}/out")"
  assertEquals "($LINENO) stderr" '' "$(< "${TD}/err")"
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"
}

function test_prompt_with_stdin_terminal_but_redirected_stderr_does_nothing()
{
  tele_run_pty '3\n' 'telemetry_paths; telemetry_prompt_consent 2> /dev/null'
  assertEquals "($LINENO) return" 1 "$TELE_PTY_RC"
  assert_lacks "$LINENO" 'question' "$TELE_PTY_OUT" 'Choice [3]:'
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"
}

function test_prompt_with_stderr_terminal_but_redirected_stdin_does_nothing()
{
  tele_run_pty '3\n' 'telemetry_paths; telemetry_prompt_consent < /dev/null'
  assertEquals "($LINENO) return" 1 "$TELE_PTY_RC"
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"
}

function test_prompt_text_has_the_three_answers_the_endpoint_and_the_preview_hint()
{
  tele_write_config 'telemetry_consent=ask' 'endpoint=http://shown.test:4318/v1/logs'
  tele_stub_set stdout.info $'pending_events=42\npending_since=2026-01-05'
  run_prompt '3\n'
  assert_has "$LINENO" 'question' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_has "$LINENO" 'option 1' "$TELE_PTY_OUT" '  1) Yes, including past data (42 events recorded since 2026-01-05)'
  assert_has "$LINENO" 'option 2' "$TELE_PTY_OUT" '  2) Yes, only from now on'
  assert_has "$LINENO" 'option 3' "$TELE_PTY_OUT" '  3) No'
  assert_has "$LINENO" 'default' "$TELE_PTY_OUT" 'Choice [3]:'
  assert_has "$LINENO" 'endpoint' "$TELE_PTY_OUT" 'http://shown.test:4318/v1/logs'
  assert_has "$LINENO" 'preview' "$TELE_PTY_OUT" 'kw telemetry upload --dry-run'
  assert_has "$LINENO" 'change your mind' "$TELE_PTY_OUT" 'kw telemetry opt-out'
  assert_has "$LINENO" 'change your mind' "$TELE_PTY_OUT" 'opt-in'
  assert_has "$LINENO" 'random id' "${TELE_PTY_OUT,,}" 'random'
}

function test_prompt_reads_the_counts_with_info_pending_and_the_exported_environment()
{
  tele_stub_set stdout.info $'pending_events=3\npending_since=2026-02-02'
  run_prompt '3\n'
  assert_equals_helper 'info call' "$LINENO" 'info --pending' "$(calls_starting_with info)"
  assert_equals_helper 'KW_TELE_CONFIG' "$LINENO" "$TELE_CONFIG" "$(tele_call_field 'info --pending' KW_TELE_CONFIG)"
  assert_equals_helper 'KW_DATA_DIR' "$LINENO" "$TELE_DATA_DIR" "$(tele_call_field 'info --pending' KW_DATA_DIR)"
  assert_equals_helper 'KW_STATE_DIR' "$LINENO" "$TELE_STATE_DIR" "$(tele_call_field 'info --pending' KW_STATE_DIR)"
  assert_equals_helper 'consent call env' "$LINENO" "$TELE_CONFIG" "$(tele_call_field 'consent --set no' KW_TELE_CONFIG)"
}

function test_prompt_with_zero_pending_events_says_no_past_data()
{
  tele_stub_set stdout.info $'pending_events=0\npending_since='
  run_prompt '3\n'
  assert_has "$LINENO" 'option 1' "$TELE_PTY_OUT" '(no past data recorded)'
  assert_lacks "$LINENO" 'no count' "$TELE_PTY_OUT" '0 events'
}

function test_prompt_uses_zero_events_when_info_fails()
{
  tele_stub_set exit.info 6
  run_prompt '2\n'
  assert_has "$LINENO" 'option 1' "$TELE_PTY_OUT" '(no past data recorded)'
  assert_equals_helper 'still records the answer' "$LINENO" 'consent --set yes' "$(calls_starting_with consent)"
}

function test_prompt_uses_zero_events_when_info_prints_garbage()
{
  tele_stub_set stdout.info 'something else'
  run_prompt '3\n'
  assert_has "$LINENO" 'option 1' "$TELE_PTY_OUT" '(no past data recorded)'
}

function test_prompt_migrates_the_schema_before_asking_for_counts()
{
  tele_make_db legacy
  run_prompt '3\n'
  tele_db_has_sent_at
  assertEquals "($LINENO) sent_at added" 0 "$?"
}

function test_prompt_leaves_no_kw_variables_in_the_caller_shell()
{
  tele_run_pty '3\n' 'telemetry_paths; telemetry_prompt_consent
[[ -v KW_VERSION ]] && echo LEAK_VERSION
[[ -v KW_TELE_CONFIG ]] && echo LEAK_CONFIG
[[ "$(declare -p KW_DATA_DIR)" == "declare -x"* ]] && echo LEAK_EXPORT_DATA
[[ "$(declare -p KW_STATE_DIR)" == "declare -x"* ]] && echo LEAK_EXPORT_STATE
echo CHECKED'
  assert_has "$LINENO" 'driver reached the checks' "$TELE_PTY_OUT" 'CHECKED'
  assert_equals_helper 'the prompt ran' "$LINENO" 'consent --set no' "$(calls_starting_with consent)"
  assert_lacks "$LINENO" 'leak' "$TELE_PTY_OUT" 'LEAK_'
}

function test_prompt_does_not_touch_the_config_file_itself()
{
  tele_write_config 'telemetry_consent=ask'
  run_prompt '1\n'
  assert_equals_helper 'the prompt ran' "$LINENO" 'consent --set yes --include-history' "$(calls_starting_with consent)"
  assert_equals_helper 'config' "$LINENO" 'telemetry_consent=ask' "$(< "$TELE_CONFIG")"
}

invoke_shunit
