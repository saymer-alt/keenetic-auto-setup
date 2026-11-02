if owned_bundle; then
    validate_bundle
else
    for path in "$LIB" "$META"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || deny 'preexisting unowned bundle; preserved'
    done
fi
