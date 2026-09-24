# Safe config.yaml import

\`config-import.sh\` bridges the user-facing gap between the generator and a running Mihomo without requiring manual editing in \`nano\`.

## Normal flow

1. Build the config in [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/).
2. Copy the complete YAML.
3. On the Keenetic router run:

\`\`\`bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/config-import.sh | sh
\`\`\`

4. Paste the YAML and press **Ctrl+D**.

Interactive input is read from \`/dev/tty\`, so this still works when the importer itself is delivered through \`curl | sh\`.

## Transaction

- the candidate is staged beside \`config.yaml\`;
- the project \`mixed-port: 7890\` contract is checked before downtime;
- a running Mihomo is stopped and confirmed down so validation never launches a second Mihomo beside the daemon;
- \`/tmp/mihomo.maintenance\` pauses the watchdog during planned downtime;
- the candidate is tested by real \`mihomo -t\`;
- the current config is saved as \`/opt/etc/mihomo/config.yaml.bak\`;
- the candidate is committed by one same-filesystem rename;
- if the service was running before import it is started again and both process state and port 7890 are checked;
- failed validation/start/port verification restores the previous config and previous service state.

The importer also refuses to begin a transaction while an \`update-mihomo.sh\` lock/process is visible.

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

## Non-goals

The importer does not generate YAML, edit proxy links, change Keenetic policy/DNS, format storage, update the Mihomo binary, or implement URL import.
