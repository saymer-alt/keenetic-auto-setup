# KAS Control Center — testing-channel web panel installation

**KAS Control Center** is an optional browser interface for an already installed [Keenetic Auto Setup](../../README.md). It does not install or replace the KAS core, Mihomo or MagiTrickle. It provides status, Doctor reports, canonical YAML import, subscription exclusions and user-confirmed update controls.

**Version policy:** testing builds change frequently. This page deliberately does not pin a beta number, an old release URL or an architecture-specific IPK filename. Use the **currently published KAS Web prerelease** for a new installation; historical builds are not an ongoing distribution channel.

## Requirements and access

- Keenetic/Netcraze with Entware, SSH and a working KAS. The default web listener needs an unambiguous private IPv4 on the management \`br0\` interface; this is not necessarily a home network.
- Determine the **actual Entware ABI** with \`opkg print-architecture\`. Published builds may include \`aarch64-3.10\`, \`armv7-3.2\`, \`mipsel-3.4\` and \`mips-3.4\`. Do not guess from the router model.
- The default listener is TCP **8081** on the \`br0\` IPv4 address. An earlier custom port may be preserved on upgrade.
- **No authentication or TLS by default.** Binding to \`br0\` does not block every routed subnet. Restrict access to trusted management networks, do not expose the UI on WAN or an unauthenticated proxy, and remember that HTTP Basic authentication does not encrypt credentials.
- No automatic IPK rollback. Back up settings and YAML before changing them; do not force package operations or interrupt an installation.

## Find and install the current package

1. Go to the project's [**GitHub Releases**](https://github.com/saymer-alt/keenetic-auto-setup/releases) page and locate the **current KAS Control Center / KAS WEB prerelease**. Do **not** use GitHub's **Latest** button: it refers to **KAS Core**, not the web UI.
2. Run \`opkg print-architecture\` on the router and download **exactly one matching IPK** together with \`SHA256SUMS\` **from the same published Web release**.
3. Transfer the files to their own directory, for example \`/tmp/kas-web-install\`, via SCP/SFTP or a trusted HTTPS download. Do not rename the IPK or mix files from different releases.
4. Verify the checksum before calling \`opkg\`. Published checksum entries may have a \`./\` prefix, so match either filename spelling.

Example that does **not** pin a version or ABI; the directory must contain precisely one selected IPK and its \`SHA256SUMS\`:

\`\`\`sh
cd /tmp/kas-web-install || exit 1
set -- kas-control-center_*.ipk
[ "$#" -eq 1 ] && [ -f "$1" ] || { echo "Expected exactly one IPK"; exit 1; }
IPK=$1
awk -v name="$IPK" '
  $2 == name || $2 == "./" name { print; found++ }
  END { if (found != 1) exit 1 }
' SHA256SUMS > selected.sha256 &&
sha256sum -c selected.sha256 &&
opkg install "./$IPK"
\`\`\`

Only proceed after \`sha256sum\` reports **OK** and package architecture matches Entware. Do not use \`opkg --force-*\`. The checksum establishes consistency with the published release but is not a substitute for trusting the source.

Start and inspect the panel:

\`\`\`sh
sh /opt/etc/init.d/S98kas-control-center start
sh /opt/etc/init.d/S98kas-control-center status
opkg status kas-control-center
\`\`\`

Open \`http://<br0-IPv4>:8081/\` or the configured custom port. Installation does not start the service automatically. If GitHub access fails on the router, fetch the verified files on a trusted PC and transfer them using SCP/SFTP.

## Operation and updates

- **Overview:** component status and manual update checks.
- **Subscriptions:** server list and reversible exclude filters through the canonical KAS importer.
- **Configuration:** paste or upload a complete YAML; back up settings before changes.
- **Diagnostics:** run Doctor and review actual warnings and failures.
- **Settings:** language, appearance, listening port and access controls; preview layouts can change.

The panel offers **Beta** and **Stable** update-channel selection. Whether a Stable build exists depends on actual publication; changing channels does not automatically install anything. Check manually and explicitly confirm installation. After an update, verify installed and running package versions, settings, filters, Doctor and real client connectivity.

An already-open browser page on some testing builds may still display the old version until a forced refresh. This is a known frontend issue, not proof that installation failed: verify the running service separately.

## Removal and recovery

\`\`\`sh
opkg remove kas-control-center
\`\`\`

This removes the optional web package, not KAS Core, Mihomo or MagiTrickle. Settings and YAML may remain. Undo applied \`exclude-filter\` in the UI **before removal** if you need those changes reverted.

There is no automatic rollback. After a failed self-update, do not start competing \`opkg\` operations; inspect \`opkg status kas-control-center\` and the service state via SSH. For \`PANEL_RECOVERY_REQUIRED\`, follow the documented \`/opt/bin/kas-control-center -recover-panel-update\` recovery process only after the active transaction is no longer running. If a reinstall is required, use a verified package from a **currently available release**, not an assumed historical asset.

Advanced network security: [LAN.md](../../web/control-center/LAN.md). Self-update protocol and recovery: [PANEL_UPDATE.md](../../web/control-center/PANEL_UPDATE.md).