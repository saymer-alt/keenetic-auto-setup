#!/bin/sh
# Opt-in wrapper; public source admission remains closed; owner-test is explicit.
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
            'status=public-install-blocked;owner-local-requires-explicit-opt-in,verified-package+device-preflight'
        ;;
    --install|--install-owner-test)
        profile=$1
        [ "$#" -eq 5 ] || { printf '%s\n' 'WDTT_INSTALL_ARGUMENTS_REJECTED' >&2; exit 78; }
        shift
        action=install
        [ "$profile" != --install-owner-test ] || action=install-owner-test
        exec /bin/sh "$(dirname "$0")/service.sh" "$action" "$@"
        ;;
    *) printf '%s\n' 'WDTT_INSTALL_BLOCKED: explicit owner-test action and verified device admission required.' >&2; exit 78 ;;
esac
