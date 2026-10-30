# opkg removes package payload. User settings/secrets are not package payload.
if [ -z "$ROOT" ]; then
    package_owned || deny 'cannot verify package service ownership'
    sh "$INIT" stop || deny 'service still draining; removal aborted'
fi
