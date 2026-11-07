#!/bin/sh
# KAS_WDTT_EXPERIMENTAL_INIT_V2. Manual is the default.
ROOT=/opt/wdtt-experimental
case ${1-}:${2-} in
    start:--manual|restart:--manual)
        exec /bin/sh "$ROOT/service.sh" "$1";;
    start:)
        if [ -f "$ROOT/auto.enabled" ] && [ ! -L "$ROOT/auto.enabled" ]; then
            exec /bin/sh "$ROOT/service.sh" boot
        fi
        printf '%s\n' WDTT_AUTOSTART_DISABLED;;
    restart:)
        /bin/sh "$ROOT/service.sh" stop || exit $?
        exec /bin/sh "$0" start;;
    enable-auto:--manual-reboot-verified)
        exec /bin/sh "$ROOT/service.sh" enable-auto --manual-reboot-verified;;
    stop:|status:|rollback:|uninstall:|disable-auto:)
        exec /bin/sh "$ROOT/service.sh" "$1";;
    *) printf '%s\n' WDTT_MANUAL_ACTION_REQUIRED >&2; exit 78;;
esac
