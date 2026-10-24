import io

p = "uninstall-transaction-gate.sh"
raw = io.open(p, encoding="utf-8", newline="").read()

# Remove the hardware-only ISP/GigabitEthernet1 special cases and the alias
# pre-scan; replace with a generic verified optional WAN deny.
old_start = raw.index("# KeeneticOS CLI may render the interface alias instead of its underlying ID")
old_end = raw.index("# A separate user host/network selector may refer to this policy; that is not")

replacement = '''# The WAN-deny line is fixture configuration, not an ownership signal:
# install.sh itself never writes it (it existed on the KN-1010 hardware
# fixture as `no permit global GigabitEthernet1` / its ISP alias; the
# Ported lab guest has none). Accept AT MOST ONE deny, and only of a name
# that is provably an interface here: either a literal `interface <name>`
# block in this same running-config read, or an alias with exactly one
# `rename <name>` directive. Any other deny stays unrecognized and blocks.
seen_description=0
seen_exit=0
seen_wan_deny=0
while IFS= read -r line; do
    case "$line" in
        '    description bypass_wa')
            [ "$seen_description" -eq 0 ] || fail "duplicate bypass_wa description"
            seen_description=1
            ;;
        '    permit global Proxy0')
            [ "$seen_exit" -eq 0 ] || fail "duplicate permit global Proxy0"
            seen_exit=1
            ;;
        '    no permit global '*)
            [ "$seen_wan_deny" -eq 0 ] || fail "duplicate WAN deny"
            _wan=${line#'    no permit global '}
            case "$_wan" in
                ''|*[!A-Za-z0-9_.-]*) fail "bypass_wa WAN deny is not an interface name" ;;
            esac
            if printf '%s\\n' "$rc" | grep -qx "interface ${_wan}"; then
                :
            elif printf '%s\\n' "$rc" | awk -v n="$_wan" '
                $1 == "rename" && $2 == n { c++ }
                END { exit !(c == 1) }
            '; then
                :
            else
                fail "bypass_wa denies a name that is neither an interface nor a unique alias: unknown shape"
            fi
            seen_wan_deny=1
            ;;
        *) fail "bypass_wa policy has an unrecognized/shared directive" ;;
    esac
done <<_POLICY
$policy_block
_POLICY
[ "$seen_description$seen_exit" = 11 ] ||
    fail "bypass_wa must have one description and one owned Proxy0 permit"
'''
raw = raw[:old_start] + replacement + raw[old_end:]
io.open(p, "w", encoding="utf-8", newline="\n").write(raw)
print("gate: generalized optional verified WAN deny")
