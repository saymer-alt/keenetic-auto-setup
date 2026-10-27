# Control Center — experimental authenticated LAN mode (not for deployment)

Stage 4 is optional and **disabled by default**. Existing localhost-only startup and Web-owned uninstall stay unchanged. The ordinary standalone service still launches 127.0.0.1:18081; no automatic LAN activation or WAN exposure is introduced.

## Why this is separate
The HTTP API can change the Mihomo configuration. Exposing it directly to a management network without TLS and authentication would give other clients control of routing, subscriptions and credentials. Reuse of an existing KeeneticOS management session has not been proven safe or supported, so this stage does not pretend to use one.

## Required controls
- `-lan` is **mandatory** for non-loopback mode. Otherwise literal loopback bind validation remains in force.
- `-listen` must be a literal private IPv4 and explicit port assigned to the **named up LAN interface**.
- `-lan-interface` names the physical/bridge Linux device; listener uses `SO_BINDTODEVICE`, with no fallback if rejected.
- `-lan-clients` is a single RFC1918 CIDR containing the listener IPv4. Requests outside it are refused; `X-Forwarded-For` is ignored.
- HTTPS TLS 1.3 is mandatory. Self-signed certificate has an IP subjectAltName matching the chosen router IPv4.
- Username is `kas`; password is a randomly generated 32-byte base64url secret. HTTP Basic Auth is only accepted inside TLS. Secret file and private key must be regular and not readable by group/others.
- Host header and Origin on write requests must exactly match the configured HTTPS listener; cross-origin and unexpected host requests are rejected.
- Never bind to `0.0.0.0`, public IP, IPv6 wildcard or inferred network device.

## Lab-only manual flow (not installed by KAS)

Create *new*, private credential directory in a disposable lab environment:

    kas-control-center -setup-lan-ip 192.168.1.1 -setup-lan-dir /opt/etc/kas-control-center-lan

One-time stdout prints the Basic Auth password and SHA-256 fingerprint. Keep the secret private; no automatic password recovery. This command never enables the listener.

Then, after reviewing the actual router/VM LAN interface name and LAN CIDR:

    kas-control-center -lan -listen 192.168.1.1:18081 -lan-interface br0 -lan-clients 192.168.1.0/24 -lan-secret-file /opt/etc/kas-control-center-lan/auth.token -tls-cert /opt/etc/kas-control-center-lan/server.crt -tls-key /opt/etc/kas-control-center-lan/server.key

Test browser access only from an allowed LAN client at `https://192.168.1.1:18081`. The generated certificate is **self-signed and untrusted by default**. A TLS warning does not justify blindly bypassing verification: validate the published SHA-256 fingerprint with the device owner out of band and, where appropriate, provision trust explicitly.

## Known blockers / no-go
- This is a transport and authentication prototype, not an installer or one-click LAN rollout. The Stage-3 service still starts on loopback.
- Tested browser/user trust workflow, interface names on actual KeeneticOS, firmware firewall isolation and guest-network/WAN reachability still require separate verification. Private IP alone is NOT proof the interface is LAN.
- No MFA, shared KeeneticOS credentials, VPN tunnel integration, account recovery, rate limiting, or external reverse proxy assumptions.
- A process crash during canonical import may leave a lost in-memory operation ID. Full power-cut recovery is a separate acceptance gate.
- CI and lab tests cannot replace actual hardware acceptance. Do not merge to main/stable or expose a real router until the above are evaluated and approved.