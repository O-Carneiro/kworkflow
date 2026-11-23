#!/usr/bin/env bash

# Fixtures shared by the telemetry tests (src/lib/telemetry.sh and src/telemetry.sh).

declare -g TELE_ENDPOINT='http://collector.test:4318/v1/logs'
declare -g TELE_DEFAULT_ENDPOINT='http://localhost:4318/v1/logs'
declare -g TELE_NOW=2000000000
declare -g TELE_INSTANCE_ID='0b5f5c60-1111-4222-8333-444455556666'
declare -g TELE_ORIG_PATH=''

# Pins every location kw and kw_tele could touch under SHUNIT_TMPDIR and puts
# the stub kw_tele first on PATH.
function tele_setup()
{
  [[ -z "$TELE_ORIG_PATH" ]] && TELE_ORIG_PATH="$PATH"
  PATH="$TELE_ORIG_PATH"

  TD="$(mktemp -d "${SHUNIT_TMPDIR}/tele.XXXXXX")"
  export HOME="${TD}/home"
  export XDG_CONFIG_HOME="${TD}/xdg/config"
  export XDG_STATE_HOME="${TD}/xdg/state"
  export XDG_DATA_HOME="${TD}/xdg/data"
  export KWORKFLOW='kw'
  export KW_TELE_TEST=1
  export KW_TELE_NOW="$TELE_NOW"
  export KW_TELE_STUB_DIR="${TD}/stub"
  export KW_LIB_DIR="${PWD}/src"
  unset -v KW_DATA_DIR KW_STATE_DIR KW_TELE_CONFIG KW_VERSION KW_ETC_DIR

  TELE_CONFIG="${XDG_CONFIG_HOME}/kw/telemetry.config"
  TELE_STATE_DIR="${XDG_STATE_HOME}/kw"
  TELE_DATA_DIR="${XDG_DATA_HOME}/kw"
  TELE_DB="${TELE_DATA_DIR}/kw.db"
  TELE_REAL_SQLITE="$(command -v sqlite3)"
  export TELE_REAL_SQLITE
  mkdir -p "$HOME" "${XDG_CONFIG_HOME}/kw" "$TELE_STATE_DIR" "$TELE_DATA_DIR" "$KW_TELE_STUB_DIR" "${TD}/stubbin"
  cp "${PWD}/tests/unit/samples/telemetry/kw_tele" "${TD}/stubbin/kw_tele"
  chmod 755 "${TD}/stubbin/kw_tele"
  PATH="${TD}/stubbin:${PATH}"
}

function tele_teardown()
{
  PATH="$TELE_ORIG_PATH"
  unset -v KW_DATA_DIR KW_STATE_DIR KW_TELE_CONFIG KW_VERSION KW_ETC_DIR
  chmod -R u+rwx "$TD" 2> /dev/null
  rm -rf "$TD"
}

# Builds TELE_LIMITED_PATH: the stub kw_tele plus a few basic tools, minus the
# ones named in the arguments.
function tele_limited_path()
{
  local bindir="${TD}/limited.$$.${RANDOM}"
  local tool
  local target

  mkdir -p "$bindir"
  for tool in bash env sqlite3 setsid timeout cat date mkdir rm sleep head grep sed tr dirname basename mktemp touch cut wc sort realpath readlink; do
    [[ " $* " == *" ${tool} "* ]] && continue
    target="$(command -v "$tool")"
    [[ -n "$target" ]] && ln -s "$target" "${bindir}/${tool}"
  done
  if [[ " $* " != *' kw_tele '* ]]; then
    cp "${TD}/stubbin/kw_tele" "${bindir}/kw_tele"
  fi
  TELE_LIMITED_PATH="$bindir"
}

# Puts a sqlite3 wrapper first on PATH (see sqlite3_race). With $1=0 the wrapper
# never applies the ALTER, so the column stays missing.
function tele_install_sqlite_race()
{
  export TELE_RACE_APPLY="${1:-1}"
  mkdir -p "${TD}/racebin"
  cp "${PWD}/tests/unit/samples/telemetry/sqlite3_race" "${TD}/racebin/sqlite3"
  chmod 755 "${TD}/racebin/sqlite3"
  PATH="${TD}/racebin:${PATH}"
}

# Puts a sqlite3 wrapper first on PATH that answers the gate's COUNT query with
# $1 (and exit status ${2:-0}) and records its arguments, one per line, in
# ${TD}/count.args.
function tele_install_fake_count()
{
  export TELE_FAKE_COUNT="$1"
  export TELE_FAKE_EXIT="${2:-0}"
  export TELE_SQLITE_RECORD="${TD}/count.args"
  mkdir -p "${TD}/countbin"
  cp "${PWD}/tests/unit/samples/telemetry/sqlite3_fake_count" "${TD}/countbin/sqlite3"
  chmod 755 "${TD}/countbin/sqlite3"
  PATH="${TD}/countbin:${PATH}"
}

# $1: control file suffix (exit, stdout, hang, exit.info, stdout.consent, ...), $2: content
function tele_stub_set()
{
  printf '%s\n' "$2" > "${KW_TELE_STUB_DIR}/${1}"
}

# Arguments are key=value lines of the config file.
function tele_write_config()
{
  mkdir -p "${TELE_CONFIG%/*}"
  printf '%s\n' "$@" > "$TELE_CONFIG"
}

# Config with valid effective consent for TELE_ENDPOINT; extra lines are appended.
function tele_consent_yes()
{
  tele_write_config 'telemetry_consent=yes' "instance_id=${TELE_INSTANCE_ID}" \
    "consented_endpoint=${TELE_ENDPOINT}" "endpoint=${TELE_ENDPOINT}" "$@"
}

# $1: last_attempt_at, $2: last_success_at, $3: consecutive_failures
function tele_write_state()
{
  mkdir -p "$TELE_STATE_DIR"
  printf 'last_attempt_at=%s\nlast_success_at=%s\nconsecutive_failures=%s\nlast_status=\n' \
    "$1" "$2" "$3" > "${TELE_STATE_DIR}/telemetry.state"
}

# Builds a kw.db from database/kwdb.sql. With 'legacy' the sent_at column and
# index are removed again, whatever kwdb.sql currently declares.
function tele_make_db()
{
  local kind="${1:-current}"

  mkdir -p "$TELE_DATA_DIR"
  rm -f "$TELE_DB"
  sqlite3 "$TELE_DB" < "${PWD}/database/kwdb.sql" > /dev/null 2>&1
  if [[ "$kind" == 'legacy' ]]; then
    sqlite3 "$TELE_DB" 'DROP INDEX IF EXISTS event_unsent_idx;' > /dev/null 2>&1
    sqlite3 "$TELE_DB" 'ALTER TABLE event DROP COLUMN sent_at;' > /dev/null 2>&1
  elif ! tele_db_has_sent_at; then
    sqlite3 "$TELE_DB" 'ALTER TABLE event ADD COLUMN sent_at INTEGER;'
  fi
}

function tele_db_has_sent_at()
{
  local columns

  columns="$(sqlite3 "$TELE_DB" "SELECT name FROM pragma_table_info('event')" 2> /dev/null)"
  [[ $'\n'"$columns"$'\n' == *$'\nsent_at\n'* ]]
}

# $1: how many rows, $2: sent_at value as SQL (default NULL)
function tele_add_events()
{
  local count="$1"
  local sent="${2:-NULL}"

  sqlite3 "$TELE_DB" "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < ${count}) INSERT INTO event (date, time, sent_at) SELECT '2026-01-01', '10:00:00', ${sent} FROM c;"
}

# Prints the argv of every recorded stub call, one per line.
function tele_calls()
{
  local argv

  [[ -r "${KW_TELE_STUB_DIR}/record" ]] || return 0
  while IFS=$'\t' read -r argv _; do
    printf '%s\n' "${argv#argv=}"
  done < "${KW_TELE_STUB_DIR}/record"
}

function tele_upload_calls()
{
  local count=0
  local call

  while IFS= read -r call; do
    [[ "$call" == 'upload' ]] && ((count++))
  done < <(tele_calls)
  printf '%s' "$count"
}

# $1: exact argv string of the call to look at, $2: field name (KW_DATA_DIR,
# KW_VERSION, sid, argc, ...). Prints the field from the first matching call.
function tele_call_field()
{
  local argv="$1"
  local name="$2"
  local line
  local field
  local -a fields

  [[ -r "${KW_TELE_STUB_DIR}/record" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "argv=${argv}"$'\t'* ]] || continue
    IFS=$'\t' read -r -a fields <<< "$line"
    for field in "${fields[@]}"; do
      if [[ "$field" == "${name}="* ]]; then
        printf '%s' "${field#"${name}="}"
        return 0
      fi
    done
  done < "${KW_TELE_STUB_DIR}/record"
  return 1
}

# Polls (at most 5 s) until the stub has recorded an upload call.
function tele_wait_for_upload()
{
  local end=$((${EPOCHREALTIME//[.,]/} + 5000000))

  while ((${EPOCHREALTIME//[.,]/} < end)); do
    [[ "$(tele_upload_calls)" -ge 1 ]] && return 0
    sleep 0.02
  done
  return 1
}

# Prints 'spawned' when the gate decided to spawn and the stub ran, 'spawn file only'
# when it decided but the stub never ran, 'not spawned' otherwise. The spawn file is
# written synchronously before the detached start, so its absence proves the decision.
function tele_spawn_outcome()
{
  if [[ -e "${KW_STATE_DIR:-${TELE_STATE_DIR}}/telemetry.spawn" ]]; then
    if tele_wait_for_upload; then
      printf 'spawned'
    else
      printf 'spawn file only'
    fi
  elif [[ "$(tele_upload_calls)" -ge 1 ]]; then
    printf 'upload without spawn file'
  else
    printf 'not spawned'
  fi
}

# Forgets earlier spawns and stub calls.
function tele_reset_spawn()
{
  rm -f "${TELE_STATE_DIR}/telemetry.spawn" "${KW_TELE_STUB_DIR}/record"
}

# Smallest number of forks function "$@" costs over five attempts, in TELE_FORKS.
# Sets TELE_FORKS=-1 when the PID counter is not readable.
function tele_count_forks()
{
  local counter='/proc/sys/kernel/ns_last_pid'
  local before
  local after
  local attempt

  TELE_FORKS=-1
  read -r before < "$counter" 2> /dev/null || return 1
  for attempt in 1 2 3 4 5; do
    read -r before < "$counter"
    "$@" < /dev/null > "${TD}/out" 2> "${TD}/err"
    read -r after < "$counter"
    if ((TELE_FORKS < 0 || after - before < TELE_FORKS)); then
      TELE_FORKS=$((after - before))
    fi
  done
}

# Runs a snippet of shell, after sourcing kw's libraries and src/lib/telemetry.sh,
# on a pseudo-terminal, feeding it $1 (printf %b) as typed input. The terminal
# output lands in TELE_PTY_OUT (CRs stripped) and the snippet's status in TELE_PTY_RC.
#
# $1: typed input, $2: snippet
function tele_run_pty()
{
  local input="$1"
  local snippet="$2"
  local driver="${TD}/driver.sh"
  local raw="${TD}/pty.raw"

  {
    printf '%s\n' '#!/usr/bin/env bash' "cd '${PWD}'" \
      "KW_LIB_DIR='${PWD}/src'" \
      '. ./src/lib/kw_include.sh --source-only' \
      'include ./src/lib/kwio.sh' \
      'include ./src/lib/kwlib.sh' \
      'include ./src/lib/telemetry.sh' \
      "${TELE_PTY_EXTRA:-:}" \
      "KW_DATA_DIR='${KW_DATA_DIR-${TELE_DATA_DIR}}'" \
      "KW_STATE_DIR='${KW_STATE_DIR-${TELE_STATE_DIR}}'" \
      "$snippet" \
      'printf "\nRC=%s\n" "$?"'
  } > "$driver"
  printf '%b' "$input" | timeout 30 script -qefc "bash ${driver}" /dev/null > "$raw" 2>&1
  TELE_PTY_OUT="$(tr -d '\r' < "$raw")"
  TELE_PTY_RC="$(sed -n 's/^RC=//p' <<< "$TELE_PTY_OUT" | tail -n 1)"
}

# $1: line, $2: message, $3: haystack, $4: needle
function assert_has()
{
  if [[ "$3" != *"$4"* ]]; then
    fail "line ${1}: ${2}: expected to find '${4}' in: ${3}"
  fi
}

# $1: line, $2: message, $3: haystack, $4: needle
function assert_lacks()
{
  if [[ "$3" == *"$4"* ]]; then
    fail "line ${1}: ${2}: did not expect '${4}' in: ${3}"
  fi
}
