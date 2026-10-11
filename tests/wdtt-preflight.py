#!/usr/bin/env python3
"""Read-only fixture regression under dash and BusyBox; no network or mount."""
import os, pathlib, subprocess, tempfile

base = pathlib.Path(__file__).resolve().parents[1]
source = (base / 'experimental/wdtt/preflight.sh').read_text()
for shell in [['sh'], ['busybox', 'ash']]:
    for arch, elf, package in [('aarch64', (2, 1, 183, 0), 'aarch64-3.10'),
                               ('mips', (1, 1, 8, 0), 'mipsel-3.4'),
                               ('mips', (1, 2, 0, 8), 'mips-3.4')]:
        with tempfile.TemporaryDirectory(prefix='wdtt-preflight-') as tmp:
            root = pathlib.Path(tmp)
            def put(name, data, mode=0o644):
                p = root / name; p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(data if isinstance(data, bytes) else data.encode()); p.chmod(mode)
            put('proc/cpuinfo', 'system type : Synthetic CPU\n')
            put('proc/meminfo', 'MemTotal: 250000 kB\nMemAvailable: 160000 kB\nSwapTotal: 200000 kB\nSwapFree: 199000 kB\n')
            put('proc/swaps', 'Filename Type Size Used Priority\n/dev/zram0 partition 200000 1000 5\n')
            put('proc/mounts', '/dev/root / squashfs ro 0 0\n/dev/sda1 ' + str(root/'opt') + ' ext4 rw 0 0\n')
            put('proc/123/comm', 'mihomo\n'); put('proc/124/comm', 'wt-client\n')
            put('proc/125/comm', 'other\n')
            # Canaries must not be read even when located next to allowed files.
            put('proc/123/cmdline', 'SECRET_ARGV_CANARY'); put('proc/123/environ', 'SECRET_ENV_CANARY')
            put('proc/net/udp', 'sl local_address rem_address st\n0: 0100007F:4A38 00000000:0000 07\n')
            put('proc/net/tcp', 'sl local_address rem_address st\n0: 0100007F:45E2 00000000:0000 0A\n1: 0100007F:0001 00000000:0000 01\n')
            put('sys/class/net/tun-lab/tun_flags', '0x0001\n')
            put('sys/class/net/eth0/ifindex', '2\n')
            data = bytearray(20); data[:4] = b'\x7fELF'
            data[4], data[5], data[18], data[19] = elf
            put('opt/bin/opkg', bytes(data))
            put('opt/etc/init.d/S00ubifs', '#!/bin/sh\n', 0o755)
            put('bin/ndmc', '#!/bin/sh\ncat <<EOF\n model: KN-FIXTURE\n hw_id: FIXTURE\n release: 5.1.6\n components: ext,ext-utils,opkg-kmod-\n netfilter\n other: ignored\nEOF\n', 0o755)
            put('bin/opkg', '#!/bin/sh\ncase $1 in print-architecture) echo "arch ' + package + ' 10";; list-installed) echo "mihomo - 1.19.32";; *) exit 99;; esac\n', 0o755)
            put('bin/uname', '#!/bin/sh\ncase $1 in -r) echo 3.10.fixture;; -m) echo ' + arch + ';; esac\n', 0o755)
            put('bin/df', '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/sda1 900000 100000 800000 12% /opt"\n', 0o755)
            put('bin/ip', '#!/bin/sh\necho "default via 192.0.2.1 dev eth0"\n', 0o755)
            # Only absolute input paths in a private COPY are redirected. The shipped
            # script has no test environment knobs and no write capability.
            script = source
            for prefix in ['/proc', '/sys', '/opt', '/dev/net/tun']:
                script = script.replace(prefix, str(root) + prefix)
            # BusyBox ash may prefer built-in applets over PATH; explicit fixture
            # functions keep uname/df/ip inputs identical in both shells.
            script = '\n'.join(f'{name}() {{ "{root}/bin/{name}" "$@"; }}' for name in ['uname', 'df', 'ip', 'ndmc', 'opkg']) + '\n' + script
            put('preflight.sh', script)
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            env = dict(os.environ, PATH=str(root/'bin') + ':' + os.environ['PATH'])
            p = subprocess.run(shell + [str(root/'preflight.sh')], env=env, capture_output=True, text=True, timeout=10)
            assert p.returncode == 0, p.stderr
            for expected in ['WDTT_PREFLIGHT_V1', 'kernel=3.10.fixture', 'machine='+arch,
                             'entware_arch '+package, 'memory_MemAvailable: 160000 kB',
                             'opt_available_kib=800000', 'fs=ext4', 'vpn_process=mihomo pid=123',
                             'vpn_process=wt-client pid=124', 'port_udp_hex=4A38', 'port_tcp_hex=45E2',
                             'tun=tun-lab', 'components=ext,ext-utils,opkg-kmod-netfilter',
                             'entware_elf_class=%s endian=%s machine_bytes=%s,%s' % elf,
                             'network_probes=NOT_RUN']:
                assert expected in p.stdout, (shell, arch, expected, p.stdout)
            assert 'SECRET_' not in p.stdout+p.stderr and 'port_tcp_hex=0001' not in p.stdout
            assert before == {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
    print('PASS preflight:', shell, 'ARM64/MIPSel/MIPS fixtures, process/TUN glob, ports, ABI evidence, resources, no writes/secrets')
