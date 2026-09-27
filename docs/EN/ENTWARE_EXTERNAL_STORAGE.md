# Entware on external USB/SSD: preparation before this project

This guide covers the case where Entware is **not installed yet** and `/opt`
will live on external Keenetic/Netcraze storage. `keenetic-auto-setup` starts
**after** a working Entware/OPKG environment exists.

> External-storage installation through the router web UI and online installation
> into internal storage are different procedures. For the external USB/SSD path,
> do not enter the internal-storage CLI command `opkg disk storage:/ https://...`.

Official Netcraze Giga NC-1012 guide:
https://support.netcraze.ru/giga/nc-1012/ru/20980.html

## 1. Prepare the partition

This project supports external `/opt` on **EXT4 only**.

If the drive has multiple partitions, decide which partition will be used for
OPKG/Entware. The project never formats, converts, or repairs storage
automatically.

## 2. Create `install`

Create this directory at the root of the selected EXT4 partition:

```text
install
```

For Giga/Netcraze NC-1012 (AArch64), the layout is:

```text
<EXT4 partition>/
└── install/
    └── aarch64-installer.tar.gz
```

Do not unpack the archive. For another model, use the architecture-specific
installer specified by its official vendor guide.

## 3. Select the storage in the web UI

Open:

```text
http://<router-IP>/opkg
```

Select the exact EXT4 partition that contains `install/<installer>.tar.gz`,
grant the required user access if needed, and click **Save**.

KeeneticOS/Netcraze OS then mounts the selected partition as `/opt`, finds the
installer, and starts Entware installation. No separate CLI installation command
is required for this path.

## 4. Watch the system log

Open **Diagnostics → System log** and wait for the installer to finish. A normal
run progresses through stages similar to:

```text
[1/5] ...
[2/5] ...
[3/5] Generating SSH keys...
[4/5] Setting timezone, script initrc and starting "dropbear"...
[5/5] "Entware" installed!
```

Treat the final `[5/5] "Entware" installed!` message as the success criterion.

If the staged installer never appears, verify the selected partition, EXT4,
the root-level `install` directory, the correct installer archive, Internet
access, and DNS resolution for `bin.entware.net`.

## 5. Router CLI is not required for external-storage installation

For the USB/SSD path, Entware installation is performed through **Files and
folders** plus the **OPKG package manager**. You do not need to open the router
CLI just to install Entware:

- no Telnet is required;
- no SSH connection to port 22 is required;
- do not manually run `opkg disk ...`;
- do not launch the installer from the router CLI.

Once `install` is prepared correctly, the proper storage is selected in OPKG,
and **Save** has been pressed, watch the system log and wait for the final
`[5/5] "Entware" installed!` message.

### If you need the router CLI for another task

The Web CLI can be opened by appending `/a` to the router address:

```text
http://<router-IP>/a
```

For example:

```text
http://192.168.1.1/a
```

This is the **router's own CLI**, not an Entware shell, and it is still not
needed for external-storage Entware installation.

The native router SSH service can also be used, normally on port 22 with a
router user such as `admin`:

```bash
ssh admin@192.168.1.1
```

On the first OpenSSH connection, answer the host-key prompt with the full word
`yes`, not just `y`. Modern macOS may not include a `telnet` command; installing
Telnet just for this workflow is unnecessary.

### Do not confuse router SSH with Entware SSH

Before Entware exists, router SSH opens the native router CLI. After Entware is
installed, a separate Dropbear instance under `/opt` becomes available. The
current vendor installer typically reports the initial Entware credentials in
the system log (commonly `root` / `keenetic` on port 222). Follow the actual
final log lines from your installation and change the initial credentials
afterward.

## 6. DNS errors are a separate failure class

`https-dns-proxy` errors are not the Entware installer itself. An HTTP 404 from
a DoH server can mean the HTTPS host is reachable but the configured DoH URL is
missing the correct endpoint path.

Before changing routing or storage, verify the current DoT/DoH profile,
`bin.entware.net` DNS resolution, router time, and Internet access from the
router itself.

## 7. Continue with this project

Only after the system log confirms `[5/5] "Entware" installed!`, enter the
Entware shell and run:

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

The project installer then performs its own storage, EXT4, KeeneticOS component,
RAM/swap, and other safety checks.
