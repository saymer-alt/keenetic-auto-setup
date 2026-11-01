# Safe config.yaml import

\`config-import.sh\` bridges the user-facing gap between the generator and a running Mihomo without requiring manual editing in \`nano\`.

## Normal flow

1. Build the config in [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/).
2. Copy the complete YAML.
3. On the Keenetic router run:

\`\`\`bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh -s -- --script config-import.sh
\`\`\`

The launcher stages `config-import.sh` privately and verifies shebang, stable project markers and `sh -n` before running it. Sources are tried in turn with bounded time: raw → IPv4/X25519 → GitHub Contents API (issue #255: a field case of `curl: (35)` on raw while IPv4/X25519 worked). The large importer is no longer executed as a partially delivered `curl | sh`. If every source fails, nothing is executed and an explicit error is printed; then download `config-import.sh` on a PC and copy it to the router over SCP/SFTP (for example `/tmp/config-import.sh`) and run `sh /tmp/config-import.sh`.

4. Paste the YAML and press **Ctrl+D**.

Interactive input is read from \`/dev/tty\`, so this still works when the importer itself is delivered through \`curl | sh\`.

## Transaction

- the candidate is staged beside \`config.yaml\`;
- the project \`mixed-port: 7890\` contract is checked before downtime;
- a running Mihomo is stopped and confirmed down so validation never launches a second Mihomo beside the daemon;
- \`/tmp/mihomo.maintenance\` pauses the watchdog during planned downtime;
- the candidate is tested by real \`mihomo -t\`;
- the current *valid* config is saved as \`/opt/etc/mihomo/config.yaml.bak\` (see "Recovery" below);
- the candidate is committed by one same-filesystem rename;
- if the service was running before import it is started again and both process state and port 7890 are checked;
- failed validation/start/port verification restores the previous config and previous service state.

In development, the importer acquires the [shared lifecycle lock (RU)](../19-lifecycle-lock.md) before stop/validation/commit and holds it through service recovery and cleanup. No separate updater-specific guard is needed: the updater uses the same lock. Existing legacy locks block acquisition; concurrent use of old and new tool copies is unsupported.

## File mode

Advanced use:

\`\`\`bash
sh config-import.sh /tmp/config.yaml
\`\`\`

The file follows the same transaction. The importer never streams input directly into the canonical config.

## Backup

After success the immediately previous configuration remains at:

\`\`\`text
/opt/etc/mihomo/config.yaml.bak
\`\`\`

A later successful import replaces that backup with the then-current config.

## Recovery (issue #320)

If the current \`config.yaml\` is missing, empty, or fails \`mihomo -t\`, the import is not blocked: KAS is provably installed (the init script was found), so the importer performs a **recovery import** of the new valid YAML and prints a \`[WARN] recovery\` line. Protection rules:

- an existing good \`config.yaml.bak\` is **never overwritten** by a missing or empty current config or by invalid nonempty content: such current content never reaches the backup;
- a failed import rolls back to the last known-good config from \`.bak\`; without a \`.bak\` the importer reports the missing rollback point honestly instead of pretending;
- **the damaged original is preserved byte-for-byte**: when the current \`config.yaml\` is nonempty but invalid, its content is copied to \`config.yaml.invalid\` (or \`config.yaml.invalid.1\`, \`.2\`, … up to \`.99\` if the name is taken) with \`0600\` permissions and a \`cmp -s\` integrity check. Publication is an **atomic create-without-overwrite**: a POSIX hard link (\`ln\` without \`-f\`) from the stage file on the same filesystem, so an existing name (a regular file, a symlink, or a dangling link) can never be overwritten even under a race — \`ln\` fails on an occupied name and the next suffix is taken. This is **not** a working backup and **not** an automatic rollback source — the file exists for manual inspection only (it may contain server addresses and subscription parameters). Existing recovery files are never overwritten, and the file content is never printed. If preservation cannot be completed safely (no space, write failure, \`cmp\` unavailable, a filesystem without hard-link support), the import aborts **before** the replacement: the original stays in place and nothing is lost;
- the misleading \`Run setup.sh first\` hint is gone in this situation: it belonged to a genuinely not-installed KAS (missing directory or init script only).

## Non-goals

The importer does not generate YAML, edit proxy links, change Keenetic policy/DNS, format storage, update the Mihomo binary, or implement URL import.

---

The importer follows the project-wide CLI status palette: green = normal progress/OK, cyan = INFO, yellow = WARN, red = ERROR/FAIL. Colors never replace the textual prefixes and are disabled for redirected output, `NO_COLOR`, or `TERM=dumb`. See [terminal output colors](OUTPUT_COLORS.md).
