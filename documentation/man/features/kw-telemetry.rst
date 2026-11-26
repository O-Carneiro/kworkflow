===================================
kw-telemetry - Share kw usage data
===================================

.. _telemetry-doc:

SYNOPSIS
========
| *kw telemetry* upload [\--dry-run]
| *kw telemetry* consent
| *kw telemetry* opt-in [\--include-history]
| *kw telemetry* opt-out
| *kw telemetry* info [\--export]
| *kw telemetry* config [\--set-upload-interval <seconds>] [\--set-upload-backoff <seconds>] [\--set-batch-size <events>]

DESCRIPTION
===========
**kw** records events about its own use in its database, such as the commands
executed with their status and duration, and the pomodoro sessions. With your
consent, `kw telemetry` uploads these events to a collector, so the developers
can learn how kw is used. Nothing is sent without consent, and the first time
kw runs on a terminal, it asks one question with three answers: share
including the events recorded so far, share only from now on, or do not share.
Answering 1, 2 or 3 records the choice at once. Any other input, Enter
included, is shown as 3 and kw asks for confirmation: Enter records that you
do not share, and 1, 2 or 3 records that choice. Any other input repeats the
confirmation. If the input ends (EOF or Ctrl-C), nothing is recorded and kw
asks again the next time. After an answer, kw tells how to change it
(`kw telemetry opt-in` or `kw telemetry opt-out`), how to see what is or would be sent
(`kw telemetry info`), how to print the JSON of the next batch without sending
it (`kw telemetry upload --dry-run`) and how to choose what is not sent
(`exclude_fields` in the config file). kw asks only when `kw_tele` is
installed and both the standard input and the standard error are terminals; otherwise it does not ask and sends nothing. It
asks before any command except `kw telemetry`, including `kw help` and
`kw version`.

Each installation has a random ID, generated when you opt in. The uploads run
in the background, at most once per backoff period, when the upload interval
has passed or enough events are pending. The work is done by the `kw_tele`
executable, installed by `setup.sh`.

The settings live in `~/.config/kw/telemetry.config`. The consent is bound to
the `endpoint` shown when you gave it: if you edit the endpoint by hand, kw asks
again.

OPTIONS
=======
upload
  Upload the pending events now, whatever the timers say.

upload \--dry-run
  Print what the next upload would send, without sending it. It works before
  you give consent.

consent
  Show whether telemetry is enabled. On a terminal, if it is not, kw offers to
  change that.

opt-in [\--include-history]
  Enable telemetry. The events recorded before this moment are excluded unless
  \--include-history is given.

opt-out
  Disable telemetry and forget the installation ID. Data already sent stays on
  the server.

info [\--export]
  Show the consent, the endpoint, the number of events pending, sent and
  excluded, the result of the last upload and which data is collected.
  \--export prints, as OTLP/JSON, every event that was sent.

config
  Show the settings and the upload state. The options \--set-upload-interval,
  \--set-upload-backoff and \--set-batch-size change them.

EXAMPLES
========
To see what would be sent before deciding::

  kw telemetry upload --dry-run

To start sharing data from now on::

  kw telemetry opt-in

To stop::

  kw telemetry opt-out
