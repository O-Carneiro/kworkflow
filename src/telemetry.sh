# The `telemetry.sh` file is the entrypoint for the `kw telemetry` feature. It
# is a thin shim over the `kw_tele` executable, which owns the telemetry
# configuration and state files and does the uploads. This file owns every
# interactive prompt.

include "${KW_LIB_DIR}/lib/kwio.sh"
include "${KW_LIB_DIR}/lib/kwlib.sh"
include "${KW_LIB_DIR}/lib/telemetry.sh"

function telemetry_main()
{
  local output
  local ret

  case "$1" in
    '' | -h | --help)
      telemetry_help
      return 0
      ;;
    upload | consent | opt-in | opt-out | info | config) ;;
    *)
      complain "Invalid telemetry subcommand: ${1}"
      telemetry_help
      return 22 # EINVAL
      ;;
  esac

  if ! command_exists 'kw_tele'; then
    complain 'Could not find the `kw_tele` executable.'
    warning 'Either run `./setup.sh --install` from the root of a kw repo or install `kw_tele` manually.'
    return 2 # ENOENT
  fi

  telemetry_paths
  telemetry_ensure_schema
  [[ "$?" == 2 ]] && warning 'kw database not found.' >&2

  case "$1" in
    upload)
      if [[ "$2" == '--dry-run' ]]; then
        telemetry_run upload --dry-run
      else
        telemetry_run upload --force
      fi
      ;;
    consent)
      output="$(telemetry_kw_tele consent)"
      ret="$?"
      printf '%s\n' "$output"
      telemetry_explain_status "$ret" || return "$?"
      if [[ "$output" == 'yes' ]]; then
        say 'To stop sharing telemetry, run `kw telemetry opt-out`.'
      elif [[ -t 0 && -t 2 ]]; then
        telemetry_prompt_consent
      fi
      return 0
      ;;
    opt-in)
      shift
      telemetry_run consent --set yes "$@"
      ;;
    opt-out)
      telemetry_run consent --set no
      ;;
    info | config)
      telemetry_run "$@"
      ;;
  esac
}

# Run kw_tele and explain its exit status.
#
# @@: Arguments for kw_tele
#
# Return:
# The exit status of kw_tele
function telemetry_run()
{
  telemetry_kw_tele "$@"
  telemetry_explain_status "$?"
}

# Print a message for a nonzero kw_tele exit status.
#
# @1: Exit status of kw_tele
#
# Return:
# The same status
function telemetry_explain_status()
{
  local ret="$1"

  case "$ret" in
    0) ;;
    3) complain 'Telemetry is not enabled; run `kw telemetry opt-in`.' ;;
    4) complain 'kw database schema is outdated.' ;;
    6) complain 'kw database not found.' ;;
    *) complain "kw_tele exited with error code ${ret}" ;;
  esac

  return "$ret"
}

function telemetry_help()
{
  printf '%s\n' 'kw telemetry:' \
    '  telemetry upload [--dry-run] - Upload the pending events now, or preview what would be sent' \
    '  telemetry consent - Show whether usage telemetry is enabled and offer to change it' \
    '  telemetry opt-in [--include-history] - Enable usage telemetry, optionally sending past events' \
    '  telemetry opt-out - Disable usage telemetry' \
    '  telemetry info [--export] - Show what is collected and sent, or export what was sent' \
    '  telemetry config [--set-upload-interval <s>] [--set-upload-backoff <s>] [--set-batch-size <n>] - Show or change the settings'
}
