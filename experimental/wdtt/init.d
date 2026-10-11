#!/bin/sh
# KAS_WDTT_EXPERIMENTAL_INIT_V1. No boot-time opt-in switch exists.
# Entware rc.unslung invokes start without --manual: no process is started.
case ${1-}:${2-} in
    start:--manual|restart:--manual)
        exec /bin/sh /opt/wdtt-experimental/service.sh "$1";;
    start:|restart:)
        printf '%s\n' WDTT_AUTOSTART_DISABLED;;
    stop:|status:|rollback:|uninstall:)
        exec /bin/sh /opt/wdtt-experimental/service.sh "$1";;
    *) printf '%s\n' WDTT_MANUAL_ACTION_REQUIRED >&2; exit 78;;
esac
