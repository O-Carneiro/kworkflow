# This file holds the telemetry gate that kw runs before every command, and
# the helpers shared with the `kw telemetry` feature (src/telemetry.sh).
#
# NOTE: The gate is sourced with `.` on every kw command, so this file must not
# depend on `include` and, until an upload is decided, must not fork more than
# once. Everything below uses builtins only, except the capped COUNT query.

declare -g TELEMETRY_DEFAULT_ENDPOINT='http://localhost:4318/v1/logs'
declare -g TELEMETRY_INT_MAX=999999999999999999
declare -g TELEMETRY_VERSION='unknown'
declare -g TELEMETRY_CONFIG=''
declare -g TELEMETRY_STATE=''
declare -g TELEMETRY_SPAWN=''
declare -g TELEMETRY_DB=''

# Set the paths of the telemetry files in TELEMETRY_CONFIG, TELEMETRY_STATE,
# TELEMETRY_SPAWN and TELEMETRY_DB. The config path ignores KW_ETC_DIR because
# consent is per user, even with a system-wide installation.
function telemetry_paths()
{
  local name="${KWORKFLOW:-kw}"
  local home="${HOME:-}"
  local state_dir="${KW_STATE_DIR:-"${XDG_STATE_HOME:-"${home}/.local/state"}/${name}"}"
  local data_dir="${KW_DATA_DIR:-"${XDG_DATA_HOME:-"${home}/.local/share"}/${name}"}"

  TELEMETRY_CONFIG="${KW_TELE_CONFIG:-"${XDG_CONFIG_HOME:-"${home}/.config"}/${name}/telemetry.config"}"
  TELEMETRY_STATE="${state_dir}/telemetry.state"
  TELEMETRY_SPAWN="${state_dir}/telemetry.spawn"
  TELEMETRY_DB="${data_dir}/kw.db"
}

# Parse a key=value file into an associative array. Keys and values are never
# evaluated. A missing or unreadable file gives an empty array.
#
# @_tkv_file: Path to the file
# @2:         Name of the associative array to fill
function telemetry_read_kv()
{
  local _tkv_file="$1"
  local -n _tkv_ref="$2"
  local _tkv_line
  local _tkv_key
  local _tkv_value

  _tkv_ref=()
  [[ -f "$_tkv_file" && -r "$_tkv_file" ]] || return 0

  while IFS= read -r _tkv_line || [[ -n "$_tkv_line" ]]; do
    [[ "$_tkv_line" == *=* ]] || continue

    _tkv_key="${_tkv_line%%=*}"
    _tkv_key="${_tkv_key#"${_tkv_key%%[![:space:]]*}"}"
    _tkv_key="${_tkv_key%"${_tkv_key##*[![:space:]]}"}"
    [[ -z "$_tkv_key" || "$_tkv_key" == '#'* ]] && continue

    _tkv_value="${_tkv_line#*=}"
    _tkv_value="${_tkv_value#"${_tkv_value%%[![:space:]]*}"}"
    _tkv_value="${_tkv_value%"${_tkv_value##*[![:space:]]}"}"

    _tkv_ref["$_tkv_key"]="$_tkv_value"
  done < "$_tkv_file"
}

# Validate an integer: no sign, no leading zero (which (( )) reads as octal) and
# at most 18 digits. Anything invalid or out of range gives the default.
#
# @1: Name of the variable that receives the result
# @2: Value to validate
# @3: Minimum
# @4: Maximum
# @5: Default
function telemetry_int()
{
  local _tint_value="$2"
  local _tint_result="$5"

  if [[ -n "$_tint_value" && "$_tint_value" != *[!0-9]* && "${#_tint_value}" -le 18 ]] &&
    [[ "$_tint_value" == 0 || "$_tint_value" != 0* ]]; then
    if ((_tint_value >= $3 && _tint_value <= $4)); then
      _tint_result="$_tint_value"
    fi
  fi
  printf -v "$1" '%s' "$_tint_result"
}

# Read telemetry.config into an associative array, replacing invalid values by
# their defaults. The key `consent` holds the effective consent: `yes` only when
# the consent is given, the instance ID is set and the endpoint is the one the
# user saw in the prompt; `no` when refused; `ask` otherwise.
#
# @1: Name of the associative array to fill
function telemetry_load_config()
{
  local -n _tkv_cfg="$1"
  local _tkv_endpoint
  local _tkv_host
  local _tkv_number

  telemetry_read_kv "$TELEMETRY_CONFIG" "$1"

  _tkv_endpoint="${_tkv_cfg[endpoint]-}"
  if [[ "$_tkv_endpoint" == http://* || "$_tkv_endpoint" == https://* ]]; then
    _tkv_host="${_tkv_endpoint#*://}"
    _tkv_host="${_tkv_host%%[/?#]*}"
    if [[ -z "$_tkv_host" || "$_tkv_host" == :* || "$_tkv_endpoint" == *[[:space:]]* ]]; then
      _tkv_endpoint="$TELEMETRY_DEFAULT_ENDPOINT"
    fi
  else
    _tkv_endpoint="$TELEMETRY_DEFAULT_ENDPOINT"
  fi
  _tkv_cfg[endpoint]="$_tkv_endpoint"

  telemetry_int _tkv_number "${_tkv_cfg[upload_interval]-}" 1 31536000 86400
  _tkv_cfg[upload_interval]="$_tkv_number"
  telemetry_int _tkv_number "${_tkv_cfg[upload_backoff]-}" 1 31536000 3600
  _tkv_cfg[upload_backoff]="$_tkv_number"
  telemetry_int _tkv_number "${_tkv_cfg[batch_size]-}" 1 5000 500
  _tkv_cfg[batch_size]="$_tkv_number"

  case "${_tkv_cfg[telemetry_consent]-}" in
    yes)
      if [[ -n "${_tkv_cfg[instance_id]-}" && "${_tkv_cfg[consented_endpoint]-}" == "$_tkv_endpoint" ]]; then
        _tkv_cfg[consent]='yes'
      else
        _tkv_cfg[consent]='ask'
      fi
      ;;
    no)
      _tkv_cfg[consent]='no'
      ;;
    *)
      _tkv_cfg[consent]='ask'
      ;;
  esac
}

# Make sure event.sent_at and the index on unsent events exist. It is safe to
# run concurrently: if the ALTER loses a race, the column is already there.
#
# Return:
# 0 if the column exists; 2 if the database does not exist; 1 if the column is
# still missing
function telemetry_ensure_schema()
{
  local columns

  [[ -n "$TELEMETRY_DB" ]] || telemetry_paths
  [[ -f "$TELEMETRY_DB" ]] || return 2 # ENOENT

  columns="$(sqlite3 -init /dev/null -cmd '.timeout 5000' "$TELEMETRY_DB" "SELECT name FROM pragma_table_info('event')" < /dev/null 2> /dev/null)"
  if [[ $'\n'"$columns"$'\n' != *$'\nsent_at\n'* ]]; then
    sqlite3 -init /dev/null -cmd '.timeout 5000' "$TELEMETRY_DB" 'ALTER TABLE event ADD COLUMN sent_at INTEGER' < /dev/null > /dev/null 2>&1
    columns="$(sqlite3 -init /dev/null -cmd '.timeout 5000' "$TELEMETRY_DB" "SELECT name FROM pragma_table_info('event')" < /dev/null 2> /dev/null)"
    [[ $'\n'"$columns"$'\n' == *$'\nsent_at\n'* ]] || return 1 # EPERM
  fi

  sqlite3 -init /dev/null -cmd '.timeout 5000' "$TELEMETRY_DB" 'CREATE INDEX IF NOT EXISTS event_unsent_idx ON event(id) WHERE sent_at IS NULL' < /dev/null > /dev/null 2>&1

  # kwdb.sql is idempotent, so it is the single source of the extension tables.
  # Run it only when the extension is missing from an old database.
  if [[ -z "$(sqlite3 -init /dev/null -cmd '.timeout 5000' "$TELEMETRY_DB" "SELECT 1 FROM sqlite_master WHERE name = 'build_modules_report'" < /dev/null 2> /dev/null)" ]]; then
    if [[ -r "${KW_DB_DIR}/kwdb.sql" ]]; then
      sqlite3 -init /dev/null -cmd '.timeout 5000' "$TELEMETRY_DB" > /dev/null 2>&1 < "${KW_DB_DIR}/kwdb.sql"
    fi
  fi

  return 0
}

# Set TELEMETRY_VERSION to the first line of ${KW_LIB_DIR}/VERSION.
function telemetry_read_version()
{
  TELEMETRY_VERSION='unknown'
  if [[ -r "${KW_LIB_DIR:-}/VERSION" ]]; then
    read -r TELEMETRY_VERSION 2> /dev/null < "${KW_LIB_DIR}/VERSION"
    TELEMETRY_VERSION="${TELEMETRY_VERSION:-unknown}"
  fi
}

# Run kw_tele with the environment it expects. The variables are exported in a
# subshell, so they do not leak into the kw run.
#
# @@: Arguments for kw_tele
function telemetry_kw_tele()
{
  [[ -n "$TELEMETRY_DB" ]] || telemetry_paths
  telemetry_read_version

  (
    KW_DATA_DIR="${TELEMETRY_DB%/*}"
    KW_STATE_DIR="${TELEMETRY_STATE%/*}"
    KW_VERSION="$TELEMETRY_VERSION"
    # shellcheck disable=SC2030,SC2031
    export KW_DATA_DIR KW_STATE_DIR KW_TELE_CONFIG="$TELEMETRY_CONFIG" KW_VERSION
    kw_tele "$@"
  )
}

# Ask the user, on the terminal, whether to share usage telemetry, and record
# the answer with kw_tele. Nothing is written when there is no terminal, when
# an answer is EOF: that is not a refusal.
#
# Return:
# 1 if nothing was asked or on EOF; otherwise the status of the kw_tele call
# that recorded the answer
function telemetry_prompt_consent()
{
  local -A prompt_config=()
  local info
  local line
  local pending=0
  local since=''
  local past_data='no past data recorded'
  local answer
  local -a reminder=()
  local confirming=0
  local status

  [[ -t 0 && -t 2 ]] || return 1 # EPERM

  telemetry_paths
  telemetry_load_config prompt_config
  reminder=(
    'To see what is or would be sent, run `kw telemetry info`. To see the JSON of'
    'the next batch without sending it, run `kw telemetry upload --dry-run`. To'
    "choose what is not sent, set \`exclude_fields\` in ${TELEMETRY_CONFIG}."
  )
  telemetry_ensure_schema

  info="$(telemetry_kw_tele info --pending 2> /dev/null)" || info=''
  while IFS= read -r line; do
    case "$line" in
      pending_events=*) pending="${line#*=}" ;;
      pending_since=*) since="${line#*=}" ;;
    esac
  done <<< "$info"
  telemetry_int pending "$pending" 0 "$TELEMETRY_INT_MAX" 0
  if ((pending > 0)); then
    past_data="${pending} events recorded since ${since:-an unknown date}"
  fi

  printf '%s\n' \
    '' \
    'kw can share usage telemetry with its developers.' \
    '  - What is sent: the usage events kw records in the tables of its' \
    '    local database, including tables added later. To see what is' \
    '    recorded, run `kw telemetry info`.' \
    "  - Where it goes: ${prompt_config[endpoint]}" \
    '  - Each installation is identified by a random ID.' \
    '  - Data that was already sent stays on the server.' \
    '  - To see what would be sent first, run `kw telemetry upload --dry-run`.' \
    '  - You can change your mind at any time with `kw telemetry opt-out` or' \
    '    `kw telemetry opt-in`.' \
    '' >&2

  printf '%s\n' \
    'Share kw usage telemetry?' \
    "  1) Yes, including past data (${past_data})" \
    '  2) Yes, only from now on' \
    '  3) No' \
    '' \
    "${reminder[@]}" \
    '' >&2
  printf '%s' 'Choice [3]: ' >&2

  while :; do
    read -r answer || return 1 # EPERM
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"

    if [[ "$confirming" == 1 && -z "$answer" ]]; then
      answer=3
    fi
    case "$answer" in
      1 | 2 | 3) break ;;
    esac

    # not an option number: show the refusal that Enter would record
    confirming=1
    printf '%s\n' \
      '' \
      'Answer: 3' \
      'You will refuse telemetry collection. Press Enter to confirm, or type 1 or 2.' >&2
    printf '%s' '> ' >&2
  done

  case "$answer" in
    1)
      telemetry_kw_tele consent --set yes --include-history
      ;;
    2)
      telemetry_kw_tele consent --set yes
      ;;
    *)
      telemetry_kw_tele consent --set no
      ;;
  esac
  status="$?"

  printf '%s\n' \
    '' \
    'To change your choice, run `kw telemetry opt-in` or `kw telemetry opt-out`.' \
    "${reminder[@]}" >&2
  return "$status"
}

# Start an upload in a detached session. telemetry.spawn is written first: it
# bounds the spawns to one per upload_backoff even if kw_tele never starts.
#
# @1: Current time, in epoch seconds
function telemetry_spawn_upload()
{
  local now="$1"

  command -v setsid > /dev/null 2>&1 || return 0
  command -v timeout > /dev/null 2>&1 || return 0

  printf '%s\n' "$now" 2> /dev/null > "$TELEMETRY_SPAWN" || return 0

  telemetry_ensure_schema

  telemetry_read_version

  (
    KW_DATA_DIR="${TELEMETRY_DB%/*}"
    KW_STATE_DIR="${TELEMETRY_STATE%/*}"
    KW_VERSION="$TELEMETRY_VERSION"
    # shellcheck disable=SC2030,SC2031
    export KW_DATA_DIR KW_STATE_DIR KW_TELE_CONFIG="$TELEMETRY_CONFIG" KW_VERSION
    exec setsid timeout 90 kw_tele upload < /dev/null > /dev/null 2>&1 &
  )
}

# Decide, before a kw command runs, whether to ask for consent or to start a
# background upload. It always returns 0 and prints nothing to stdout, so a
# telemetry problem can never break a kw command.
#
# @1: First argument of the kw command
function telemetry_gate()
{
  local action="${1:-}"
  local -A config=()
  local -A state=()
  local now
  local spawned_at=0
  local last_attempt
  local last_success
  local failures
  local backoff
  local interval
  local batch_size
  local gap
  local gap_cap
  local count

  [[ "$action" == telemetry ]] && return 0

  command -v kw_tele > /dev/null 2>&1 || return 0

  telemetry_paths
  telemetry_load_config config
  case "${config[consent]}" in
    no) return 0 ;;
    ask)
      telemetry_prompt_consent >&2
      return 0
      ;;
  esac

  # these actions never record events, so they neither upload nor spawn
  case "$action" in
    '' | help | h | --help | -h | man | version | --version | -v) return 0 ;;
  esac

  telemetry_read_kv "$TELEMETRY_STATE" state
  telemetry_int last_attempt "${state[last_attempt_at]-}" 0 "$TELEMETRY_INT_MAX" 0
  telemetry_int last_success "${state[last_success_at]-}" 0 "$TELEMETRY_INT_MAX" 0
  telemetry_int failures "${state[consecutive_failures]-}" 0 "$TELEMETRY_INT_MAX" 0
  if [[ -f "$TELEMETRY_SPAWN" && -r "$TELEMETRY_SPAWN" ]]; then
    read -r spawned_at 2> /dev/null < "$TELEMETRY_SPAWN"
  fi
  telemetry_int spawned_at "$spawned_at" 0 "$TELEMETRY_INT_MAX" 0

  backoff="${config[upload_backoff]}"
  interval="${config[upload_interval]}"
  batch_size="${config[batch_size]}"

  # KW_TELE_NOW lets the tests control the clock; it is ignored otherwise
  if [[ "${KW_TELE_TEST:-}" == 1 ]]; then
    telemetry_int now "${KW_TELE_NOW:-}" 0 "$TELEMETRY_INT_MAX" -1
  else
    now=-1
  fi
  ((now < 0)) && printf -v now '%(%s)T' -1

  # a timestamp in the future (clock jump, copied state) would block the gate
  ((last_attempt > now)) && last_attempt=0
  ((last_success > now)) && last_success=0
  ((spawned_at > now)) && spawned_at=0

  gap="$backoff"
  if ((failures > 0)); then
    failures=$((failures > 21 ? 20 : failures - 1))
    gap_cap=$((interval > backoff ? interval : backoff))
    gap=$((backoff << failures))
    ((gap > gap_cap)) && gap="$gap_cap"
  fi

  ((now >= last_attempt + gap && now >= spawned_at + backoff)) || return 0

  if ((now >= last_success + interval)); then
    telemetry_spawn_upload "$now"
    return 0
  fi

  # -readonly keeps sqlite3 from creating a missing database and -init
  # /dev/null from reading ~/.sqliterc
  [[ -f "$TELEMETRY_DB" ]] || return 0
  {
    count="$(sqlite3 -readonly -batch -noheader -init /dev/null -cmd '.timeout 100' "$TELEMETRY_DB" "SELECT COUNT(*) FROM (SELECT 1 FROM event WHERE sent_at IS NULL LIMIT ${batch_size})")"
  } 2> /dev/null || return 0
  telemetry_int count "$count" 0 "$TELEMETRY_INT_MAX" -1
  if ((count >= batch_size)); then
    telemetry_spawn_upload "$now"
  fi

  return 0
}
