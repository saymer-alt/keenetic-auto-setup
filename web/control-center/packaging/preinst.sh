# Refuse adoption of manual installs. opkg owns payload management on upgrades.
if [ -e "$OPT/etc/kas-control-center.web.sha256" ] || [ -L "$OPT/etc/kas-control-center.web.sha256" ]; then
    deny 'preexisting manual ownership manifest; remove using the original helper first'
fi
if package_owned; then
    [ -f "$OPT/bin/kas-control-center" ] && [ ! -L "$OPT/bin/kas-control-center" ] || deny 'unsafe installed binary'
    if [ -z "$ROOT" ]; then
        sh "$INIT" stop || deny 'service did not drain; upgrade aborted'
    fi
else
    for p in "$OPT/bin/kas-control-center" "$INIT" "$OPT/share/kas-control-center/BUILD_INFO" "$OPT/share/kas-control-center/THIRD_PARTY_NOTICES"; do
        [ ! -e "$p" ] && [ ! -L "$p" ] || deny "preexisting unowned file: $p"
    done
fi
