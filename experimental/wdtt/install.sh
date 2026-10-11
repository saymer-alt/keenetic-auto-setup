#!/bin/sh
# Admission boundary: research prototypes must never install on a router yet.
# No network access, filesystem mutation, package manager or service execution.
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
    *) printf '%s\n' 'WDTT_INSTALL_BLOCKED: licensing, server authentication and real-pair gates remain open.' >&2; exit 78 ;;
esac
