#!/bin/sh
# Opt-in wrapper; reviewed source admission in service.sh remains closed.
# No downloads, package manager, routing, DNS, firewall or KAS integration.
case ${1-} in
    --plan)
        printf '%s\n' 'WDTT_INSTALL_PLAN_V1' \
            'target=isolated-test-device-only' \
            'required=private-config,source+patch+toolchain+binary-checksums,actual-ELF-ABI,RAM,opt-space,exclusive-loopback-port' \
            'payload=own-versioned-directory,manual-init-only,previous-own-manifest' \
            'runtime=no-default-route,no-DNS-change,no-firewall-change,no-KAS-Mihomo-overwrite' \
            'rollback=verified-own-PID-stop,atomic-previous-binary-restore' \
            'uninstall=verified-own-manifest-only' \
            'reboot=disabled-until-live-acceptance' \
            'status=BLOCKED license-notices,server-auth,real-pair,installer-rollback-acceptance'
        ;;
    --install)
        [ "$#" -eq 5 ] || { printf '%s\n' 'WDTT_INSTALL_ARGUMENTS_REJECTED' >&2; exit 78; }
        shift
        exec /bin/sh "$(dirname "$0")/service.sh" install "$@"
        ;;
    *) printf '%s\n' 'WDTT_INSTALL_BLOCKED: licensing, server authentication and real-pair gates remain open.' >&2; exit 78 ;;
esac
