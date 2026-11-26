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

# Prints a state-file timestamp for "N seconds before now"; 'never' is 0 and a
# negative N lands in the future.
function seconds_ago()
{
  if [[ "$1" == never ]]; then
    printf '0'
  else
    printf '%s' $((TELE_NOW - $1))
  fi
}

# Runs the gate against scenarios read from stdin, one per row:
#   config lines (comma separated) | expected outcome | attempt age | success age | failures
# The ages are seconds before now (see seconds_ago).
#
# @line: $LINENO of the caller
function check_timing_rows()
{
  local line="$1"
  local cfgs
  local expected
  local attempt
  local success
  local failures
  local -a cfg

  tele_make_db
  while IFS='|' read -r cfgs expected attempt success failures; do
    IFS=',' read -r -a cfg <<< "$cfgs"
    tele_reset_spawn
    tele_consent_yes "${cfg[@]}"
    tele_write_state "$(seconds_ago "$attempt")" "$(seconds_ago "$success")" "$failures"
    run_gate build "$line"
    assert_gate_outcome "$line" "$expected" "[${cfgs:-defaults}] attempt=${attempt} success=${success} failures=${failures}"
  done
}

# ------------------------------------------------------------ telemetry_read_kv

# Prints the array as sorted key=value lines, so one comparison covers it all.
function dump_kv()
{
  local -n _dump_ref="$1"
  local key

  for key in "${!_dump_ref[@]}"; do
    printf '%s=%s\n' "$key" "${_dump_ref[$key]}"
  done | LC_ALL=C sort
}

function test_read_kv_grammar()
{
  local -A kv=()
  local expected

  # One file with every construct: CRLF, trimming (inner space kept), comments
  # and blank lines, last duplicate wins, the first '=' splits, no inline
  # comments, empty values, case-sensitive keys, CR on an unterminated last line.
  printf 'a=1\r\n  b  =   two words  \r\n# c=3\n\n   \nd=1\nd=2\nd=3\nendpoint=http://h:1/p?a=b=c\nn=5 # not a comment\ninstance_id=\nKey=1\nlast=7\r' > "${TD}/kv"
  telemetry_read_kv "${TD}/kv" kv
  assertEquals "($LINENO)" 0 "$?"
  expected='Key=1
a=1
b=two words
d=3
endpoint=http://h:1/p?a=b=c
instance_id=
last=7
n=5 # not a comment'
  assert_equals_helper 'whole parsed array' "$LINENO" "$expected" "$(dump_kv kv)"
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

# Prints the config, state and db paths, one per line.
function paths_triplet()
{
  telemetry_paths
  printf '%s\n%s\n%s' "$TELEMETRY_CONFIG" "$TELEMETRY_STATE" "$TELEMETRY_DB"
}

# The variants run in command substitutions, so the variables they set do not
# outlive the call.
function paths_with_kworkflow_name()
{
  export KWORKFLOW='.kw'
  paths_triplet
}

function paths_with_defaults()
{
  unset -v KWORKFLOW
  export KW_ETC_DIR="${TD}/etc"
  paths_triplet
}

function paths_with_kw_variables()
{
  export KW_TELE_CONFIG="${TD}/elsewhere/t.config" KW_STATE_DIR="${TD}/st" KW_DATA_DIR="${TD}/da"
  paths_triplet
}

function test_paths_resolution()
{
  local expected

  expected="${XDG_CONFIG_HOME}/.kw/telemetry.config"$'\n'"${XDG_STATE_HOME}/.kw/telemetry.state"$'\n'"${XDG_DATA_HOME}/.kw/kw.db"
  assert_equals_helper 'KWORKFLOW names the directory' "$LINENO" "$expected" "$(paths_with_kworkflow_name)"

  expected="${XDG_CONFIG_HOME}/kw/telemetry.config"$'\n'"${XDG_STATE_HOME}/kw/telemetry.state"$'\n'"${XDG_DATA_HOME}/kw/kw.db"
  assert_equals_helper 'default name is kw, KW_ETC_DIR is ignored' "$LINENO" "$expected" "$(paths_with_defaults)"

  expected="${TD}/elsewhere/t.config"$'\n'"${TD}/st/telemetry.state"$'\n'"${TD}/da/kw.db"
  assert_equals_helper 'KW_* variables win over XDG' "$LINENO" "$expected" "$(paths_with_kw_variables)"
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
#
# @1: $LINENO of the caller
# @2: 'unset' to start with TELEMETRY_DB empty, as when the paths were never resolved
function ensure_schema_quiet()
{
  if [[ "${2:-}" == unset ]]; then
    TELEMETRY_DB=''
  else
    telemetry_paths
  fi
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

function test_ensure_schema()
{
  local label
  local db
  local wrapper
  local paths
  local expected
  local saved_path="$PATH"

  # db: legacy (no sent_at), current or none. wrapper: a sqlite3 in front of the
  # real one, 'race' (another kw wins the ALTER) or 'stuck' (the ALTER never
  # applies). paths: 'unset' leaves TELEMETRY_DB empty. expected is the status
  # (2: no DB, 1: the column is still missing).
  while IFS='|' read -r label db wrapper paths expected; do
    PATH="$saved_path"
    rm -f "$TELE_DB"
    [[ "$db" == none ]] || tele_make_db "$db"
    case "$wrapper" in
      race) tele_install_sqlite_race 1 ;;
      stuck) tele_install_sqlite_race 0 ;;
    esac
    ensure_schema_quiet "$LINENO" "$paths"
    assertEquals "(${label}) status" "$expected" "$SCHEMA_RC"
    [[ "$db" == none ]] && assertFalse "(${label}) must not create the DB" "[[ -e ${TELE_DB} ]]"
    PATH="$saved_path"
    if [[ "$expected" == 0 ]]; then
      tele_db_has_sent_at
      assertEquals "(${label}) sent_at column" 0 "$?"
      index_is_partial_on_id
      assertEquals "(${label}) partial index event_unsent_idx(id) WHERE sent_at IS NULL" 0 "$?"
    elif [[ "$expected" == 1 ]]; then
      tele_db_has_sent_at
      assertEquals "(${label}) sent_at column still missing" 1 "$?"
    fi
  done << 'EOF'
old DB|legacy|-|set|0
current DB|current|-|set|0
no DB|none|-|set|2
paths not resolved yet|legacy|-|unset|0
another kw wins the ALTER race|legacy|race|set|0
ALTER never applies|legacy|stuck|set|1
EOF
}

function test_ensure_schema_keeps_the_rows_and_leaves_them_pending()
{
  tele_make_db legacy
  sqlite3 "$TELE_DB" "INSERT INTO event (date, time) VALUES ('2026-01-01', '10:00:00'), ('2026-01-02', NULL)"
  ensure_schema_quiet "$LINENO"
  assert_equals_helper 'rows kept, all pending' "$LINENO" '2|2' \
    "$(sqlite3 "$TELE_DB" 'SELECT COUNT(*) || char(124) || COUNT(*) FILTER (WHERE sent_at IS NULL) FROM event')"
}

# kwdb.sql is the single source of the extension tables, so it must run exactly
# when the report view is missing. A stand-in kwdb.sql leaves a marker table.
function test_ensure_schema_runs_kwdb_sql_only_when_the_extension_is_missing()
{
  local label
  local view
  local dir
  local expected

  mkdir -p "${TD}/dbdir" "${TD}/emptydir"
  printf '%s\n' 'CREATE TABLE IF NOT EXISTS ran_marker (x);' > "${TD}/dbdir/kwdb.sql"

  # view: whether the report view is dropped first. dir: dbdir (holds kwdb.sql),
  # emptydir (does not) or unset (KW_DB_DIR itself unset).
  while IFS='|' read -r label view dir expected; do
    tele_make_db
    [[ "$view" == dropped ]] && sqlite3 "$TELE_DB" 'DROP VIEW build_modules_report'
    if [[ "$dir" == unset ]]; then
      unset -v KW_DB_DIR
    else
      KW_DB_DIR="${TD}/${dir}"
    fi
    ensure_schema_quiet "$LINENO"
    assertEquals "(${label}) status" 0 "$SCHEMA_RC"
    assertEquals "(${label}) kwdb.sql ran" "$expected" "$(sqlite3 "$TELE_DB" "SELECT count(*) FROM sqlite_master WHERE name = 'ran_marker'")"
  done << 'EOF'
view missing|dropped|dbdir|1
view present|kept|dbdir|0
view missing, KW_DB_DIR unset|dropped|unset|0
view missing, no kwdb.sql there|dropped|emptydir|0
EOF
}

# ---------------------------------------------------------------- telemetry_gate

function test_gate_consent_states()
{
  local label
  local consent
  local id
  local consented
  local endpoint
  local expected
  local before

  # Only a yes with an instance_id and a consented_endpoint equal to the
  # effective endpoint (the default one when unset) spawns. The gate never
  # writes the config.
  # label | telemetry_consent | instance_id | consented_endpoint | endpoint | outcome
  while IFS='|' read -r label consent id consented endpoint expected; do
    tele_write_config "telemetry_consent=${consent}" "instance_id=${id}" \
      "consented_endpoint=${consented}" ${endpoint:+"endpoint=${endpoint}"}
    before="$(< "$TELE_CONFIG")"
    tele_reset_spawn
    run_gate build "$LINENO"
    assertEquals "(${label}) stderr" '' "$GATE_ERR"
    assert_gate_outcome "$LINENO" "$expected" "$label"
    assert_equals_helper "${label}: config unchanged" "$LINENO" "$before" "$(< "$TELE_CONFIG")"
    [[ "$expected" == spawned ]] || assertEquals "(${label}) no kw_tele call at all" '' "$(tele_calls)"
  done << EOF
consent=yes|yes|${TELE_INSTANCE_ID}|${TELE_ENDPOINT}|${TELE_ENDPOINT}|spawned
default endpoint when unset|yes|${TELE_INSTANCE_ID}|${TELE_DEFAULT_ENDPOINT}||spawned
consent=no|no|${TELE_INSTANCE_ID}|${TELE_ENDPOINT}|${TELE_ENDPOINT}|not spawned
consent=ask without a terminal|ask|${TELE_INSTANCE_ID}|${TELE_ENDPOINT}|${TELE_ENDPOINT}|not spawned
empty instance_id|yes||${TELE_ENDPOINT}|${TELE_ENDPOINT}|not spawned
edited endpoint|yes|${TELE_INSTANCE_ID}|http://a.test/v1/logs|http://b.test/v1/logs|not spawned
trailing slash|yes|${TELE_INSTANCE_ID}|http://a.test/v1/logs|http://a.test/v1/logs/|not spawned
empty consented_endpoint|yes|${TELE_INSTANCE_ID}||http://a.test/v1/logs|not spawned
endpoint case differs|yes|${TELE_INSTANCE_ID}|http://A.test/v1/logs|http://a.test/v1/logs|not spawned
unknown value (case-sensitive)|YES|${TELE_INSTANCE_ID}|${TELE_ENDPOINT}|${TELE_ENDPOINT}|not spawned
EOF

  rm -f "$TELE_CONFIG"
  tele_reset_spawn
  run_gate build "$LINENO"
  assertEquals "($LINENO) missing config: stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'missing config counts as ask'
  assertFalse "($LINENO) config created" "[[ -e ${TELE_CONFIG} ]]"
}

# With consent=yes these actions return before the timing and the spawn, even
# when an upload is due (D53). Consent is read first, so the skip list only
# keeps help and version from starting uploads.
function test_gate_exempt_actions_do_not_spawn_when_consent_is_yes()
{
  local action

  tele_consent_yes
  for action in '' telemetry help h --help -h man version --version -v; do
    tele_reset_spawn
    run_gate "$action" "$LINENO"
    assert_gate_outcome "$LINENO" 'not spawned' "action '${action}'"
    assertEquals "($LINENO) action '${action}' stderr" '' "$GATE_ERR"
    assertEquals "($LINENO) action '${action}' no kw_tele call" '' "$(tele_calls)"
  done
}

# Runs the gate on a terminal for one action, with stdout in a file.
#
# @action: First argument of the kw command
# @input: Typed input (printf %b)
function run_gate_on_terminal()
{
  tele_run_pty "$2" "telemetry_gate '${1}' > '${TD}/gate.stdout'"
}

# Consent is checked for every action but `telemetry` (D53): the prompt shows
# when consent is `ask`, help and version included, and never when it is `no`
# or `yes`. kw_tele missing silences it.
function test_gate_prompts_on_a_terminal_only_when_consent_is_not_effective()
{
  local label
  local consent
  local action
  local prompted
  local calls

  # The gate must return 0 and leave stdout empty on every row.
  # label | consent | action | prompt shown
  while IFS='|' read -r label consent action prompted; do
    if [[ "$consent" == yes ]]; then
      tele_consent_yes
    else
      tele_write_config "telemetry_consent=${consent}"
    fi
    tele_reset_spawn
    run_gate_on_terminal "$action" '3\n'
    assertEquals "(${label}) gate returned 0" 0 "$TELE_PTY_RC"
    if [[ "$prompted" == yes ]]; then
      assert_has "$LINENO" "${label}: prompt" "$TELE_PTY_OUT" 'Share kw usage telemetry?'
      assert_equals_helper "${label}: one question" "$LINENO" 1 "$(count_choice_lines)"
      assert_equals_helper "${label}: answer recorded" "$LINENO" $'info --pending\nconsent --set no' "$(tele_calls)"
    else
      assert_lacks "$LINENO" "${label}: no prompt" "$TELE_PTY_OUT" 'Share kw usage telemetry?'
      assert_equals_helper "${label}: no kw_tele call" "$LINENO" '' "$(tele_calls)"
    fi
    assertEquals "(${label}) stdout" '' "$(< "${TD}/gate.stdout")"
  done << 'EOF'
build, ask|ask|build|yes
help, ask|ask|help|yes
h, ask|ask|h|yes
--help, ask|ask|--help|yes
-h, ask|ask|-h|yes
man, ask|ask|man|yes
version, ask|ask|version|yes
--version, ask|ask|--version|yes
-v, ask|ask|-v|yes
empty action, ask|ask||yes
telemetry, ask|ask|telemetry|no
build, no|no|build|no
help, no|no|help|no
telemetry, no|no|telemetry|no
help, yes|yes|help|no
EOF

  # A yes whose endpoint changed counts as ask, and the prompt shows the new one.
  tele_write_config 'telemetry_consent=yes' "instance_id=${TELE_INSTANCE_ID}" \
    'consented_endpoint=http://old.test/v1/logs' 'endpoint=http://new.test/v1/logs'
  tele_reset_spawn
  run_gate_on_terminal build '3\n'
  assert_has "$LINENO" 'endpoint mismatch prompts again' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_has "$LINENO" 'new endpoint shown' "$TELE_PTY_OUT" 'http://new.test/v1/logs'
}

# The answer is recorded and nothing uploads on the same command, so a yes to
# the prompt does not spawn at once either.
function test_gate_prompt_writes_to_stderr_and_does_not_spawn()
{
  tele_write_config 'telemetry_consent=ask'
  tele_stub_set stdout 'noise from kw_tele'
  tele_stub_set stdout.info $'pending_events=2\npending_since=2026-01-05'
  tele_run_pty '1\n' "telemetry_gate build > '${TD}/gate.stdout'"
  assertEquals "($LINENO) gate returned 0" 0 "$TELE_PTY_RC"
  assert_has "$LINENO" 'answer 1' "$(tele_calls)" 'consent --set yes --include-history'
  assert_lacks "$LINENO" 'nothing uploads on the same command' "$(tele_calls)" 'upload'
  assertFalse "($LINENO) spawn file" "[[ -e ${TELE_STATE_DIR}/telemetry.spawn ]]"
  assertEquals "($LINENO) kw_tele output must not reach stdout" '' "$(< "${TD}/gate.stdout")"
}

# Without kw_tele nothing prompts, whatever the action.
function test_gate_without_kw_tele_never_prompts()
{
  local action

  tele_write_config 'telemetry_consent=ask'
  tele_limited_path kw_tele
  for action in build help ''; do
    TELE_PTY_EXTRA="PATH='${TELE_LIMITED_PATH}'" run_gate_on_terminal "$action" '3\n'
    assertEquals "(action '${action}') gate returned 0" 0 "$TELE_PTY_RC"
    assert_lacks "$LINENO" "action '${action}': no prompt" "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  done
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"
}

# Without both terminals nothing is asked, whatever the action, and nothing
# runs: no kw_tele call, no sqlite call, no output.
function test_gate_with_consent_ask_and_no_terminal_does_nothing()
{
  local label
  local action
  local stdin_kind

  mkdir -p "${TD}/sqlbin"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$*\" >> '${TD}/sqlite.calls'" > "${TD}/sqlbin/sqlite3"
  chmod 755 "${TD}/sqlbin/sqlite3"
  PATH="${TD}/sqlbin:${PATH}"
  tele_make_db 2> /dev/null || true
  tele_write_config 'telemetry_consent=ask'
  : > "${TD}/sqlite.calls"

  # label | action | what stdin is
  while IFS='|' read -r label action stdin_kind; do
    rm -f "${KW_TELE_STUB_DIR}/record"
    : > "${TD}/sqlite.calls"
    if [[ "$stdin_kind" == pipe ]]; then
      printf '3\n' | telemetry_gate "$action" > "${TD}/gate.out" 2> "${TD}/gate.err"
    else
      telemetry_gate "$action" < /dev/null > "${TD}/gate.out" 2> "${TD}/gate.err"
    fi
    assertEquals "(${label}) return" 0 "$?"
    assertEquals "(${label}) stdout" '' "$(< "${TD}/gate.out")"
    assertEquals "(${label}) stderr" '' "$(< "${TD}/gate.err")"
    assertEquals "(${label}) no kw_tele call" '' "$(tele_calls)"
    assertEquals "(${label}) no sqlite call" '' "$(< "${TD}/sqlite.calls")"
    assertFalse "(${label}) no spawn file" "[[ -e ${TELE_STATE_DIR}/telemetry.spawn ]]"
  done << 'EOF'
help, stdin /dev/null|help|null
help, stdin a pipe|help|pipe
build, stdin /dev/null|build|null
build, stdin a pipe|build|pipe
EOF
}

# One terminal is not enough: both stdin and stderr must be terminals.
function test_gate_with_only_one_terminal_does_not_prompt()
{
  local label
  local action
  local redirect

  tele_write_config 'telemetry_consent=ask'
  # label | action | redirection of the gate call
  while IFS='|' read -r label action redirect; do
    rm -f "${KW_TELE_STUB_DIR}/record" "${TD}/gate.stderr"
    tele_run_pty '3\n' "telemetry_gate ${action} ${redirect//TD/${TD}}"
    assertEquals "(${label}) gate returned 0" 0 "$TELE_PTY_RC"
    assert_lacks "$LINENO" "${label}: no prompt on the terminal" "$TELE_PTY_OUT" 'Share kw usage telemetry?'
    [[ -e "${TD}/gate.stderr" ]] && assertEquals "(${label}) no prompt in the stderr file" '' "$(< "${TD}/gate.stderr")"
    assertEquals "(${label}) no kw_tele call" '' "$(tele_calls)"
  done << 'EOF'
only stderr a tty, build|build|< /dev/null
only stderr a tty, help|help|< /dev/null
only stdin a tty, build|build|2> 'TD/gate.stderr'
only stdin a tty, help|help|2> 'TD/gate.stderr'
EOF
}

function test_gate_spawns_only_when_due()
{
  # A last_success_at or last_attempt_at in the future (clock jump, copied
  # state) must not block spawning. The failure gap doubles from 3600 s per
  # failure and is capped at 86400 s.
  # config | outcome | attempt age | success age | failures
  check_timing_rows "$LINENO" << 'EOF'
|spawned|never|86400|0
|not spawned|never|86399|0
|not spawned|3599|never|0
|spawned|3600|never|0
|not spawned|7199|never|2
|spawned|7200|never|2
|not spawned|86399|never|30
|spawned|86400|never|30
|spawned|never|-864000|0
|spawned|-864000|never|0
EOF
}

function test_gate_timing_follows_the_config_values()
{
  # The failure gap is capped by the larger of upload_interval and
  # upload_backoff. A value outside the integer grammar falls back to the
  # default (backoff 3600 s, interval 86400 s), and is never evaluated.
  rm -f /tmp/kw_tele_pwned
  check_timing_rows "$LINENO" << 'EOF'
upload_backoff=60|not spawned|59|never|0
upload_backoff=60|spawned|60|never|0
upload_interval=100|not spawned|never|99|0
upload_interval=100|spawned|never|100|0
upload_backoff=100000,upload_interval=50|not spawned|99999|never|3
upload_backoff=100000,upload_interval=50|spawned|100000|never|3
upload_backoff=08|not spawned|2000|never|0
upload_backoff=010|not spawned|100|never|0
upload_backoff=soon|not spawned|2000|never|0
upload_backoff=1+1|not spawned|2000|never|0
upload_backoff=a[$(touch /tmp/kw_tele_pwned)]|not spawned|2000|never|0
upload_backoff = 100 |spawned|2000|never|0
EOF
  assertFalse "($LINENO) config value was evaluated" '[[ -e /tmp/kw_tele_pwned ]]'
}

# telemetry_int is what keeps the state file, the spawn file and the config
# from being evaluated as arithmetic.
function test_telemetry_int_grammar()
{
  local label
  local value
  local min
  local max
  local fallback
  local expected
  local out

  # label | value | min | max | default | result
  while IFS='|' read -r label value min max fallback expected; do
    out='unset'
    telemetry_int out "$value" "$min" "$max" "$fallback"
    assert_equals_helper "$label" "$LINENO" "$expected" "$out"
  done << 'EOF'
zero is valid|0|0|10|7|0
the maximum is inclusive|10|0|10|7|10
above the maximum|11|0|10|7|7
the minimum is inclusive|5|5|10|7|5
below the minimum|4|5|10|7|7
leading zero (octal)|010|0|99|7|7
only zeros|00|0|99|7|7
empty|''|0|99|7|7
sign|-1|0|99|7|7
plus sign|+1|0|99|7|7
trailing space|1 |0|99|7|7
arithmetic|1+1|0|99|7|7
18 digits|999999999999999999|0|9223372036854775807|7|999999999999999999
19 digits|1000000000000000000|0|9223372036854775807|7|7
20 digits wrap around int64|99999999999999999999|0|9223372036854775807|7|7
EOF
  # an empty row value stands for the empty string
  telemetry_int out '' 0 99 7
  assert_equals_helper 'empty string' "$LINENO" 7 "$out"
}

# The state file is read on every kw command, so a hostile value must stay
# data and the gate must read it as invalid (zero), which makes an upload due.
function test_gate_state_values_are_not_evaluated()
{
  local key
  local marker="${TD}/state_pwned"

  tele_consent_yes
  for key in last_attempt_at last_success_at consecutive_failures; do
    rm -f "$marker"
    tele_reset_spawn
    printf 'last_attempt_at=0\nlast_success_at=0\nconsecutive_failures=0\n%s=a[$(touch %s)]\n' "$key" "$marker" > "${TELE_STATE_DIR}/telemetry.state"
    run_gate build "$LINENO"
    assertFalse "(${key}) the value was evaluated" "[[ -e ${marker} ]]"
    assertEquals "(${key}) stderr" '' "$GATE_ERR"
    assert_gate_outcome "$LINENO" spawned "hostile ${key} reads as invalid"
  done
}

# The spawn file bounds spawns to one per backoff. Garbage or a future value
# must not block uploads for good (D40, D47).
function test_gate_spawn_file_content()
{
  local label
  local content
  local expected
  local marker="${TD}/spawn_pwned"

  # content | spawn file after the run: 'now' (spawned) or 'kept'
  while IFS='|' read -r label content expected; do
    rm -f "$marker"
    tele_reset_spawn
    tele_consent_yes
    printf '%s\n' "$content" > "${TELE_STATE_DIR}/telemetry.spawn"
    run_gate build "$LINENO"
    assertFalse "(${label}) the value was evaluated" "[[ -e ${marker} ]]"
    if [[ "$expected" == now ]]; then
      assertEquals "(${label}) spawn file rewritten" "$TELE_NOW" "$(< "${TELE_STATE_DIR}/telemetry.spawn")"
      assertTrue "(${label}) upload ran" tele_wait_for_upload
    else
      assertEquals "(${label}) spawn file kept" "$content" "$(< "${TELE_STATE_DIR}/telemetry.spawn")"
      assertEquals "(${label}) no upload" 0 "$(tele_upload_calls)"
    fi
  done << EOF
recent spawn blocks|$((TELE_NOW - 10))|kept
garbage|abc|now
negative|-5|now
leading zero|010|now
in the future|$((TELE_NOW + 100000))|now
arithmetic|a[\$(touch ${TD}/spawn_pwned)]|now
EOF
}

# KW_TELE_NOW is a test hook: without KW_TELE_TEST=1 the real clock is used,
# and an invalid value under the flag also falls back to it. The state below
# is recent only against the fake clock; against the real one it lies in the
# future, so it counts as never and an upload is due.
function test_gate_clock_override_needs_the_test_flag()
{
  local label
  local flag
  local now_value
  local expected

  tele_consent_yes
  # label | KW_TELE_TEST | KW_TELE_NOW | outcome
  while IFS='|' read -r label flag now_value expected; do
    tele_reset_spawn
    tele_write_state $((TELE_NOW - 10)) 0 0
    KW_TELE_TEST="$flag" KW_TELE_NOW="$now_value" run_gate build "$LINENO"
    assert_gate_outcome "$LINENO" "$expected" "$label"
  done << EOF
flag set, fake clock honoured|1|${TELE_NOW}|not spawned
flag unset, fake clock ignored||${TELE_NOW}|spawned
flag 0, fake clock ignored|0|${TELE_NOW}|spawned
flag set, garbage clock falls back to the real one|1|soon|spawned
EOF
}

function test_gate_second_call_inside_the_backoff_does_not_spawn()
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

function test_gate_spawns_at_the_batch_size()
{
  local cfg
  local pending
  local attempt
  local expected

  # Rows already sent or excluded (sent_at set) never count. The success age of
  # 100 s keeps the time trigger off. An invalid batch_size falls back to 500.
  # config | pending rows | attempt age | outcome
  while IFS='|' read -r cfg pending attempt expected; do
    tele_reset_spawn
    tele_make_db
    tele_add_events "$pending"
    tele_add_events 3 -1
    tele_add_events 3 1700000000
    tele_consent_yes "$cfg"
    tele_write_state "$(seconds_ago "$attempt")" $((TELE_NOW - 100)) 0
    run_gate build "$LINENO"
    assertEquals "(${cfg} pending=${pending}) stderr" '' "$GATE_ERR"
    assert_gate_outcome "$LINENO" "$expected" "${cfg} with ${pending} pending, attempt ${attempt}"
  done << 'EOF'
batch_size=5|4|never|not spawned
batch_size=5|5|never|spawned
batch_size=5|9|100|not spawned
batch_size=0|100|never|not spawned
batch_size=lots|100|never|not spawned
EOF
}

function test_gate_bad_count_does_not_spawn()
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
failure with a big number|99|1
EOF
}

# The COUNT runs on every kw command, so it must not read ~/.sqliterc (which
# could run commands) or be able to create a database.
function test_gate_count_query_ignores_the_users_sqliterc()
{
  local -a argv

  tele_consent_yes 'batch_size=5'
  tele_make_db
  tele_write_state 0 $((TELE_NOW - 100)) 0

  tele_install_fake_count 0
  run_gate build "$LINENO"
  mapfile -t argv < "$TELE_SQLITE_RECORD"
  assert_equals_helper 'read-only flag' "$LINENO" 1 "$(printf '%s\n' "${argv[@]}" | grep -c -x -e '-readonly')"
  assert_equals_helper 'rc file replaced by /dev/null' "$LINENO" '-init|/dev/null' "$(printf '%s\n' "${argv[@]}" | grep -x -A1 -e '-init' | paste -sd'|' -)"

  PATH="${TELE_ORIG_PATH}"
  PATH="${TD}/stubbin:${PATH}"
  mkdir -p "$HOME"
  printf '%s\n' ".shell touch ${TD}/sqliterc_ran" > "${HOME}/.sqliterc"
  tele_reset_spawn
  run_gate build "$LINENO"
  assertFalse "($LINENO) ~/.sqliterc was read" "[[ -e ${TD}/sqliterc_ran ]]"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
}

function test_gate_count_without_a_usable_db_is_silent()
{
  tele_consent_yes
  tele_write_state 0 $((TELE_NOW - 100)) 0
  tele_make_db legacy
  run_gate build "$LINENO"
  assertEquals "($LINENO) legacy DB: stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'no sent_at column'
  tele_db_has_sent_at
  assertEquals "($LINENO) the gate must not migrate on the COUNT path" 1 "$?"

  rm -f "$TELE_DB"
  tele_reset_spawn
  run_gate build "$LINENO"
  assertEquals "($LINENO) missing DB: stderr" '' "$GATE_ERR"
  assert_gate_outcome "$LINENO" 'not spawned' 'no DB'
  assertFalse "($LINENO) DB created" "[[ -e ${TELE_DB} ]]"
}

# What the uploader is started with: argv and the environment kw_tele reads.
function test_gate_spawn_passes_the_kw_environment()
{
  tele_consent_yes
  tele_write_state 5 6 1
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assert_equals_helper 'argv' "$LINENO" 'upload' "$(tele_calls)"
  assert_equals_helper 'argc' "$LINENO" '1' "$(tele_call_field upload argc)"
  assert_equals_helper 'KW_TELE_CONFIG' "$LINENO" "$TELE_CONFIG" "$(tele_call_field upload KW_TELE_CONFIG)"
  assert_equals_helper 'KW_DATA_DIR' "$LINENO" "$TELE_DATA_DIR" "$(tele_call_field upload KW_DATA_DIR)"
  assert_equals_helper 'KW_STATE_DIR' "$LINENO" "$TELE_STATE_DIR" "$(tele_call_field upload KW_STATE_DIR)"
  assert_equals_helper 'KW_VERSION' "$LINENO" "$(head -n 1 ./src/VERSION)" "$(tele_call_field upload KW_VERSION)"
}

# The uploader must outlive the kw command and never touch its terminal.
function test_gate_spawn_is_detached_from_the_command()
{
  local my_sid
  local -a stat_fields

  tele_consent_yes
  : > "${TD}/stdin.src"
  read -r -a stat_fields < "/proc/$$/stat"
  my_sid="${stat_fields[5]}"
  telemetry_gate build < "${TD}/stdin.src" > "${TD}/gate.out" 2> "${TD}/gate.err"
  assert_gate_outcome "$LINENO" spawned 'due'
  assertNotEquals "($LINENO) new session" "$my_sid" "$(tele_call_field upload sid)"
  assert_has "$LINENO" 'wrapped in timeout 90' "$(tele_call_field upload parent)" 'timeout 90 kw_tele upload'
  assert_equals_helper 'stdin' "$LINENO" '/dev/null' "$(tele_call_field upload stdin)"
  assert_equals_helper 'stdout' "$LINENO" '/dev/null' "$(tele_call_field upload stdout)"
  assert_equals_helper 'stderr' "$LINENO" '/dev/null' "$(tele_call_field upload stderr)"
  assertEquals "($LINENO) gate stdout" '' "$(< "${TD}/gate.out")"
  assertEquals "($LINENO) gate stderr" '' "$(< "${TD}/gate.err")"
}

function test_gate_spawn_writes_only_the_spawn_file()
{
  local config_before
  local state_before
  local files

  tele_consent_yes
  tele_write_state 5 6 1
  config_before="$(< "$TELE_CONFIG")"
  state_before="$(< "${TELE_STATE_DIR}/telemetry.state")"
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  assert_equals_helper 'spawn file holds the time of the spawn' "$LINENO" "$TELE_NOW" "$(< "${TELE_STATE_DIR}/telemetry.spawn")"
  assert_equals_helper 'config untouched' "$LINENO" "$config_before" "$(< "$TELE_CONFIG")"
  assert_equals_helper 'state untouched' "$LINENO" "$state_before" "$(< "${TELE_STATE_DIR}/telemetry.state")"
  files="$(cd "$TELE_STATE_DIR" && printf '%s ' *)"
  assert_equals_helper 'only the spawn file is added to the state dir' "$LINENO" 'telemetry.spawn telemetry.state ' "$files"
}

# An old DB is migrated before the uploader starts.
function test_gate_spawn_migrates_an_old_db_first()
{
  tele_consent_yes
  tele_make_db legacy
  run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'due'
  tele_db_has_sent_at
  assertEquals "($LINENO) sent_at added before the uploader starts" 0 "$?"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
}

# If the spawn file cannot be written the gate gives up silently: spawning
# without it would defeat the backoff.
function test_gate_does_not_spawn_when_the_spawn_file_cannot_be_written()
{
  tele_consent_yes
  chmod 555 "$TELE_STATE_DIR"
  run_gate build "$LINENO"
  sleep 0.5
  chmod 755 "$TELE_STATE_DIR"
  assertEquals "($LINENO) stderr" '' "$GATE_ERR"
  assertEquals "($LINENO) no upload" 0 "$(tele_upload_calls)"
}

function test_gate_does_not_wait_for_the_uploader()
{
  local start
  local elapsed
  local out

  tele_consent_yes
  tele_stub_set hang 5
  start=${EPOCHREALTIME//[.,]/}
  out="$(telemetry_gate build < /dev/null 2>&1)"
  elapsed=$((${EPOCHREALTIME//[.,]/} - start))
  assertEquals "($LINENO) output" '' "$out"
  assertTrue "($LINENO) the gate took ${elapsed} us with a 5 s uploader" "((elapsed < 3000000))"
}

function test_gate_does_not_spawn_without_a_required_tool()
{
  local tool

  tele_consent_yes
  for tool in setsid timeout kw_tele; do
    tele_reset_spawn
    tele_limited_path "$tool"
    GATE_PATH="$TELE_LIMITED_PATH" run_gate build "$LINENO"
    assertEquals "(no ${tool}) stderr" '' "$GATE_ERR"
    assert_gate_outcome "$LINENO" 'not spawned' "no ${tool}"
    assertFalse "(no ${tool}) spawn file" "[[ -e ${TELE_STATE_DIR}/telemetry.spawn ]]"
  done

  tele_reset_spawn
  tele_limited_path
  GATE_PATH="$TELE_LIMITED_PATH" run_gate build "$LINENO"
  assert_gate_outcome "$LINENO" spawned 'control: limited PATH holding every needed tool'
}

function gate_with_limited_path()
{
  PATH="$TELE_LIMITED_PATH" telemetry_gate build
}

# KW_TELE_TEST=0 makes the gate read the real clock.
function gate_with_the_real_clock()
{
  local KW_TELE_TEST=0

  telemetry_gate build
}

# Forks are counted through ns_last_pid, so the test skips where that is unreadable.
function test_gate_fork_budget()
{
  local label
  local kind
  local expected
  local real_now
  local failed_rows=''

  tele_make_db
  tele_count_forks :
  if ((TELE_FORKS < 0)); then
    startSkipping
    return
  fi

  # Until an upload is decided the gate may fork at most once, for the COUNT.
  # label | scenario | forks
  while IFS='|' read -r label kind expected; do
    rm -f "${TELE_STATE_DIR}/telemetry.state" "${TELE_STATE_DIR}/telemetry.spawn" "$TELE_SQLITE_RECORD"
    tele_consent_yes
    case "$kind" in
      no) tele_write_config 'telemetry_consent=no' ;;
      ask) tele_write_config 'telemetry_consent=ask' ;;
      spacing) tele_write_state $((TELE_NOW - 10)) $((TELE_NOW - 10)) 0 ;;
      realclock)
        printf -v real_now '%(%s)T' -1
        tele_write_state $((real_now - 10)) $((real_now - 10)) 0
        ;;
      nodb)
        rm -f "$TELE_DB"
        tele_consent_yes 'batch_size=5'
        tele_write_state 0 $((TELE_NOW - 100)) 0
        ;;
      count)
        tele_consent_yes 'batch_size=5'
        tele_install_fake_count 0
        tele_write_state 0 $((TELE_NOW - 100)) 0
        ;;
    esac
    case "$kind" in
      nokwtele)
        tele_limited_path kw_tele
        tele_count_forks gate_with_limited_path
        ;;
      realclock) tele_count_forks gate_with_the_real_clock ;;
      help) tele_count_forks telemetry_gate help ;;
      *) tele_count_forks telemetry_gate build ;;
    esac
    assert_equals_helper "$label" "$LINENO" "$expected" "$TELE_FORKS"
    [[ "$kind" == nodb ]] && tele_make_db
    if [[ "$kind" == count ]]; then
      assertTrue "(${label}) the COUNT query must have run" "[[ -s ${TELE_SQLITE_RECORD} ]]"
      assertEquals "(${label}) still no spawn" 0 "$(tele_upload_calls)"
    fi
  done << 'EOF'
consent=no|no|0
consent=ask without a terminal|ask|0
help with consent=yes returns before the timing|help|0
spacing not ok|spacing|0
spacing not ok on the real clock|realclock|0
no kw_tele|nokwtele|0
COUNT path without a DB|nodb|0
below batch: one COUNT fork|count|1
EOF
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

# Number of lines of the pty output that hold the confirmation step of D56.
function count_confirmations()
{
  local line
  local count=0

  while IFS= read -r line; do
    [[ "$line" == *refuse* ]] && ((count++))
  done <<< "$TELE_PTY_OUT"
  printf '%s' "$count"
}

# D56: 1, 2 and 3 are recorded at once. Any other input shows the answer 3 and
# asks to confirm the refusal: Enter records no, 1 or 2 records that choice,
# anything else repeats the confirmation. EOF at any step records nothing.
function test_prompt_answers()
{
  local input
  local rc
  local expected
  local asks
  local confirmations
  local exit_code

  # typed input (printf %b) | return | consent call | times asked | times the
  # confirmation is shown | exit status of the consent call ('-': default); the
  # return is the status of that call
  while IFS='|' read -r input rc expected asks confirmations exit_code; do
    tele_reset_spawn
    rm -f "${KW_TELE_STUB_DIR}/exit.consent"
    [[ "$exit_code" == '-' ]] || tele_stub_set exit.consent "$exit_code"
    run_prompt "$input"
    assertEquals "(input '${input}') return" "$rc" "$TELE_PTY_RC"
    assert_equals_helper "input '${input}': consent calls" "$LINENO" "$expected" "$(calls_starting_with consent)"
    assert_equals_helper "input '${input}': times asked" "$LINENO" "$asks" "$(count_choice_lines)"
    assert_equals_helper "input '${input}': confirmations" "$LINENO" "$confirmations" "$(count_confirmations)"
  done << 'EOF'
1\n|0|consent --set yes --include-history|1|0|-
2\n|0|consent --set yes|1|0|-
3\n|0|consent --set no|1|0|-
  1 \n|0|consent --set yes --include-history|1|0|-
\n\n|0|consent --set no|1|1|-
y\n\n|0|consent --set no|1|1|-
yes\n\n|0|consent --set no|1|1|-
n\n\n|0|consent --set no|1|1|-
x\n\n|0|consent --set no|1|1|-
0\n\n|0|consent --set no|1|1|-
4\n\n|0|consent --set no|1|1|-
y\n1\n|0|consent --set yes --include-history|1|1|-
y\n2\n|0|consent --set yes|1|1|-
x\n3\n|0|consent --set no|1|1|-
y\nx\n\n|0|consent --set no|1|2|-
y\nx\n2\n|0|consent --set yes|1|2|-
y\nx\nz\n\n|0|consent --set no|1|3|-
1\n|6|consent --set yes --include-history|1|0|6
2\n|4|consent --set yes|1|0|4
3\n|3|consent --set no|1|0|3
\n\n|5|consent --set no|1|1|5
|1||1|0|-
y\n|1||1|1|-
y\nx\n|1||1|2|-
EOF
}

# The confirmation names what will be recorded: the answer line shows 3 and the
# text says that telemetry is refused and that Enter confirms.
function test_prompt_confirmation_text()
{
  local input
  local after_first
  local first_step

  for input in '\n' 'y\n' 'x\n'; do
    run_prompt "${input}\n"
    after_first="${TELE_PTY_OUT#*'Choice [3]: '}"
    first_step="${after_first%%'> '*}"
    assert_has "$LINENO" "input '${input}': refusal named" "$first_step" 'refuse'
    assert_has "$LINENO" "input '${input}': Enter confirms" "$first_step" 'Enter'
    assert_has "$LINENO" "input '${input}': the answer line shows 3" "$first_step" '3'
    assert_has "$LINENO" "input '${input}': 1 or 2 offered" "$first_step" '1 or 2'
  done
}

function test_prompt_without_both_terminals_does_nothing()
{
  telemetry_paths
  telemetry_prompt_consent < /dev/null > "${TD}/out" 2> "${TD}/err"
  assertEquals "($LINENO) return" 1 "$?"
  assertEquals "($LINENO) stdout" '' "$(< "${TD}/out")"
  assertEquals "($LINENO) stderr" '' "$(< "${TD}/err")"
  assertEquals "($LINENO) no kw_tele call" '' "$(tele_calls)"

}

function test_prompt_text()
{
  local flat

  tele_write_config 'telemetry_consent=ask' 'endpoint=http://shown.test:4318/v1/logs'
  tele_stub_set stdout.info $'pending_events=42\npending_since=2026-01-05'
  run_prompt '3\n'
  flat="$(tr -s ' ' <<< "${TELE_PTY_OUT//$'\n'/ }")"
  assert_has "$LINENO" 'question' "$TELE_PTY_OUT" 'Share kw usage telemetry?'
  assert_has "$LINENO" 'option 1' "$TELE_PTY_OUT" '  1) Yes, including past data (42 events recorded since 2026-01-05)'
  assert_has "$LINENO" 'option 2' "$TELE_PTY_OUT" '  2) Yes, only from now on'
  assert_has "$LINENO" 'option 3' "$TELE_PTY_OUT" '  3) No'
  assert_has "$LINENO" 'endpoint' "$TELE_PTY_OUT" 'http://shown.test:4318/v1/logs'
  assert_has "$LINENO" 'source of the data' "$flat" 'local database'
  assert_has "$LINENO" 'tables added later' "$flat" 'added later'
  assert_has "$LINENO" 'dry run' "$flat" 'kw telemetry upload --dry-run'
}

# D55 and D56: the question and the line after every recorded answer remind the
# user how to see what is sent (`kw telemetry info`) and how to leave fields out
# (exclude_fields in the config file, whose path is printed). The recorded line
# also says how to change the answer.
function test_prompt_reminds_how_to_see_and_limit_what_is_sent()
{
  local input
  local marker='Choice [3]: '
  local before_choice
  local after_choice
  local needle

  # the question is the same for every answer, so the typed input only varies
  # the text printed after it. The inputs that need a confirmation end with Enter.
  for input in '1\n' '2\n' '3\n' '\n\n' 'y\n\n' 'x\n1\n'; do
    run_prompt "$input"
    before_choice="${TELE_PTY_OUT%%"$marker"*}"
    after_choice="${TELE_PTY_OUT##*"$marker"}"
    for needle in 'kw telemetry info' 'exclude_fields' 'kw telemetry upload --dry-run' "$TELE_CONFIG"; do
      assert_has "$LINENO" "question text, input '${input}'" "$before_choice" "$needle"
      assert_has "$LINENO" "text after the answer, input '${input}'" "$after_choice" "$needle"
    done
    for needle in 'To change your choice' 'kw telemetry opt-in' 'kw telemetry opt-out'; do
      assert_has "$LINENO" "change line, input '${input}'" "$after_choice" "$needle"
    done
    assert_lacks "$LINENO" "no per-answer line, input '${input}'" "$after_choice" 'You chose'
  done
}

# Everything the prompt prints, the confirmation included, goes to stderr.
function test_prompt_prints_nothing_on_stdout()
{
  local input

  for input in '2\n' 'y\n\n' 'y\nx\n3\n'; do
    tele_run_pty "$input" "telemetry_paths; telemetry_prompt_consent > '${TD}/prompt.stdout'"
    assertEquals "(input '${input}') return" 0 "$TELE_PTY_RC"
    assert_has "$LINENO" "input '${input}': the prompt is on the terminal" "$TELE_PTY_OUT" 'Share kw usage telemetry?'
    assertEquals "(input '${input}') stdout" '' "$(< "${TD}/prompt.stdout")"
  done
}

function test_prompt_does_not_enumerate_a_fixed_field_list()
{
  local flat
  local column
  local found=''

  tele_make_db
  run_prompt '3\n'
  flat="${TELE_PTY_OUT//$'\n'/ }"
  flat="$(tr -s ' ' <<< "$flat")"
  # Names with an underscore cannot be ordinary words (id, time, ...), so a
  # match means the prompt spells out a table or column.
  while IFS= read -r column; do
    [[ "${flat,,}" == *"$column"* ]] && found+=" ${column}"
  done < <(sqlite3 "$TELE_DB" "SELECT m.name FROM sqlite_master m WHERE m.type = 'table' UNION SELECT p.name FROM sqlite_master m, pragma_table_info(m.name) p WHERE m.type = 'table'" | grep _)
  assertEquals "($LINENO) kwdb.sql columns named in the prompt" '' "$found"
}

function test_prompt_reads_counts_from_kw_tele()
{
  tele_stub_set stdout.info $'pending_events=3\npending_since=2026-02-02'
  run_prompt '3\n'
  assert_equals_helper 'info call' "$LINENO" 'info --pending' "$(calls_starting_with info)"
  assert_equals_helper 'KW_TELE_CONFIG' "$LINENO" "$TELE_CONFIG" "$(tele_call_field 'info --pending' KW_TELE_CONFIG)"
  assert_equals_helper 'KW_DATA_DIR' "$LINENO" "$TELE_DATA_DIR" "$(tele_call_field 'info --pending' KW_DATA_DIR)"
  assert_equals_helper 'KW_STATE_DIR' "$LINENO" "$TELE_STATE_DIR" "$(tele_call_field 'info --pending' KW_STATE_DIR)"
  assert_equals_helper 'consent call env' "$LINENO" "$TELE_CONFIG" "$(tele_call_field 'consent --set no' KW_TELE_CONFIG)"
}

function test_prompt_without_counts()
{
  local label
  local info

  # label | stub for `info --pending` | text expected in option 1
  while IFS='|' read -r label info; do
    rm -f "${KW_TELE_STUB_DIR}/exit.info" "${KW_TELE_STUB_DIR}/stdout.info"
    case "$label" in
      'zero events') tele_stub_set stdout.info $'pending_events=0\npending_since=' ;;
      'info fails') tele_stub_set exit.info 6 ;;
      'garbage count') tele_stub_set stdout.info $'pending_events=a[1]\npending_since=2026-01-01' ;;
      'count without a date') tele_stub_set stdout.info $'pending_events=4\npending_since=' ;;
    esac
    tele_reset_spawn
    run_prompt '2\n'
    assert_has "$LINENO" "option 1 (${label})" "$TELE_PTY_OUT" "$info"
    assert_equals_helper "still records the answer (${label})" "$LINENO" 'consent --set yes' "$(calls_starting_with consent)"
  done << 'EOF'
zero events|(no past data recorded)
info fails|(no past data recorded)
garbage count|(no past data recorded)
count without a date|(4 events recorded since an unknown date)
EOF
}

invoke_shunit
