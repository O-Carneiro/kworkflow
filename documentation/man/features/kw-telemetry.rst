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
Without a terminal, kw does not ask and sends nothing.

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
