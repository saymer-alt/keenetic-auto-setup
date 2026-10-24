import io

p = "tests/uninstall-remove-regression.py"
raw = io.open(p, encoding="utf-8", newline="").read().replace("
", "
")

old = '''BASE_CONFIG = """interface Bridge0
    description Home
!
interface Proxy0'''
new = '''BASE_CONFIG = """interface Bridge0
    description Home
!
interface GigabitEthernet1
    rename ISP
    security-level public
    up
!
interface Proxy0'''
assert raw.count(old) == 1
raw = raw.replace(old, new)

# Ported shape: policy WITHOUT any WAN deny must pass the gate
anchor = '''    # duplicated ip global must block'''
addition = '''    # Ported shape: install.sh never writes a WAN deny; the policy block is
    # description + owned permit only. The gate must accept it.
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-ported-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td, ip_global=PROXY_32767)
        rc = (state / "running-config").read_text().replace(
            "    no permit global GigabitEthernet1\\n", "")
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        print("[PASS]", shell, "gate: Ported policy without WAN deny")

    # A deny of a name that is neither an interface nor a unique alias blocks
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-deny-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        rc = (state / "running-config").read_text().replace(
            "    no permit global GigabitEthernet1\\n",
            "    no permit global Vpn9\\n")
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 3 and "unknown shape" in p.stderr, p.stderr
        print("[PASS]", shell, "gate: WAN deny of unknown interface blocked")

    # An alias deny with exactly one rename stays acceptable (KN-1010 ISP form)
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-alias-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        rc = (state / "running-config").read_text().replace(
            "    no permit global GigabitEthernet1\\n", "    no permit global ISP\\n")
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        print("[PASS]", shell, "gate: alias WAN deny with unique rename")

    # duplicated ip global must block'''
assert raw.count(anchor) == 1
raw = raw.replace(anchor, addition)

io.open(p, "w", encoding="utf-8", newline="\n").write(raw)
print("gate fixture tests extended")
