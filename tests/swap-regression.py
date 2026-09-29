#!/usr/bin/env python3
"""C1: exercise all three production scanners with identical kernel fixtures.

ls supplies block-device metadata (no privileged mknod or active swap needed).
The real identity helper, mount classifiers, scanners and installer policy run
under both shells. No swap is created or enabled.
"""
from pathlib import Path
import subprocess
import tempfile
import shlex

ROOT=Path(__file__).resolve().parents[1]
SOURCES={n:(ROOT/n).read_text() for n in ['install.sh','mihomo-doctor.sh','update-mihomo.sh']}


def identity(s):
    return s[s.index('# BEGIN ZRAM IDENTITY v1'):s.index('# END ZRAM IDENTITY v1')]


def main():
    assert len({identity(s) for s in SOURCES.values()})==1
    cases=[
        ('zram0','/dev/zram0 partition 524288 0 100',524288,0,0),
        ('zram1','/dev/zram1 partition 524288 0 100',524288,0,0),
        ('file named zram','/tmp/mnt/disk/zram.swap file 524288 0 -1',0,524288,0),
        ('opt file named zram','/opt/my-zram-file file 524288 0 -1',0,524288,0),
        ('oversize zram filename','/tmp/mnt/disk/zram.swap file 2200000 0 -1',0,2200000,0),
        ('128 external floor','/tmp/mnt/disk/zram.swap file 393216 0 -1',0,393216,0),
        ('coexistence','/dev/zram0 partition 524288 0 100\n/opt/zram.swap file 524288 0 -1',524288,524288,0),
        ('fake device name','/dev/zramfake partition 524288 0 100',0,0,524288),
        ('contradictory sysfs','/dev/zram2 partition 524288 0 100',0,0,524288),
        ('unreadable sysfs','/dev/zram3 partition 524288 0 100',0,0,524288),
        ('regular file masquerading as device','/dev/zram4 partition 524288 0 100',0,0,524288),
        ('nonexternal swapfile','/swapfile file 524288 0 -1',0,0,524288),
        ('plain opt swapfile','/opt/swapfile file 524288 0 -1',0,524288,0),
        ('escaped mount name','/tmp/mnt/zram\\040disk/swapfile file 524288 0 -1',0,524288,0),
        ('deleted source','/opt/zram.swap\\040(deleted) file 524288 0 -1',0,0,0),
        ('multiple storage','/opt/zram.swap file 400000 0 -1\n/opt/swapfile file 400000 0 -2',0,800000,0),
        ('wrong swap type','/dev/zram0 file 524288 0 100',0,0,524288),
    ]
    total=0
    for shell in [['sh'],['busybox','ash']]:
        with tempfile.TemporaryDirectory(prefix='swap-identity-') as directory:
            lab=Path(directory);sys=lab/'sys';sys.mkdir()
            for i,dev in [(0,'252:0'),(1,'252:1'),(2,'1:2'),(4,'252:4')]:
                (sys/f'zram{i}').mkdir();(sys/f'zram{i}/dev').write_text(dev+'\n')
            mounts=lab/'mounts';mounts.write_text('/dev/sda2 /opt ext4 rw 0 0\n/dev/sdb1 /tmp/mnt/disk ext4 rw 0 0\n/dev/sdc1 /tmp/mnt/zram\\040disk ext4 rw 0 0\n')
            swaps=lab/'swaps';mem=lab/'mem';mem.write_text('MemTotal: 524288 kB\nSwapTotal: 524288 kB\n')
            pre=f'''set -e
ls() {{
    case "$*" in
        *'/dev/zram4') echo '-rw------- 1 0 0 0 Jan 1 00:00 /dev/zram4' ;;
        *'/dev/zram0') echo 'brw------- 1 0 0 252, 0 Jan 1 00:00 /dev/zram0' ;;
        *'/dev/zram1') echo 'brw------- 1 0 0 252, 1 Jan 1 00:00 /dev/zram1' ;;
        *'/dev/zram2') echo 'brw------- 1 0 0 252, 2 Jan 1 00:00 /dev/zram2' ;;
        *'/dev/zram3') echo 'brw------- 1 0 0 252, 3 Jan 1 00:00 /dev/zram3' ;;
        *) command ls "$@" ;;
    esac
}}
SYS_CLASS_BLOCK={shlex.quote(str(sys))}; DOC_SYS_CLASS_BLOCK=$SYS_CLASS_BLOCK; UP_SYS_CLASS_BLOCK=$SYS_CLASS_BLOCK
PROC_MOUNTS={shlex.quote(str(mounts))}; MOUNTS_SRC=$PROC_MOUNTS; UP_MOUNTS=$PROC_MOUNTS
PROC_SWAPS={shlex.quote(str(swaps))}; SWAPS_SRC=$PROC_SWAPS; UP_SWAPS=$PROC_SWAPS
SWAP_MAX_KB=2097152; DOC_SWAP_MAX_KB=2097152
'''
            for name,s in SOURCES.items():
                if name=='install.sh':
                    code=s[s.index('# BEGIN ZRAM IDENTITY v1'):s.index('MEMINFO=')]
                    invoke='scan_swap_backends';values='$SW_ZRAM_KB:$SW_EXT_KB:$SW_UNVER_KB'
                elif name=='mihomo-doctor.sh':
                    code=s[s.index('# BEGIN ZRAM IDENTITY v1'):s.index('_doc_opt=$(_doc_opt_class)')]
                    invoke='_doc_scan_swap || true';values='$_doc_zram_kb:$_doc_ext_kb:$_doc_unver_kb'
                else:
                    code=s[s.index('# BEGIN ZRAM IDENTITY v1'):s.index('TOTAL_MEM_KB=$(awk')]
                    invoke='_up_scan_swap';values='$UP_ZRAM_KB:$UP_EXT_KB:$UP_UNVER_KB'
                for label,rows,z,e,u in cases:
                    swaps.write_text('Filename Type Size Used Priority\n'+rows+'\n')
                    p=subprocess.run(shell,input=pre+code+f'\n{invoke}\nprintf "%s" "{values}"\n',text=True,capture_output=True)
                    assert p.returncode==0 and p.stdout==f'{z}:{e}:{u}',(shell,name,label,p.returncode,p.stdout,p.stderr)
                    total+=1
            # Actual installer policy, including size gates and backend severities.
            s=SOURCES['install.sh'];policy=s[s.index('RESOURCE_PROFILE_CONTRACT_VERSION='):s.index('# REQUIRED KEENETICOS COMPONENT PREFLIGHT')]
            for label,rows,ram,reject,needle in [
                ('oversize disguised file',cases[4][1],524288,True,'exceeds the 2 GiB'),
                ('128 disk floor',cases[5][1],131072,False,'LOW-RAM / BEST-EFFORT'),
                ('128 zram only',cases[0][1],131072,True,'required at least 384 MB'),
                ('512 real zram',cases[0][1],524288,False,'512 MB-class with active zRAM'),
                ('512 named disk',cases[2][1],524288,False,'512 MB-class with external storage-backed'),
                ('coexistence',cases[6][1],524288,False,'active together'),
                ('256 unknown',cases[9][1],254472,False,'neither active zRAM'),
                ('512 unknown',cases[9][1],524288,True,'Bare 512 MB RAM'),
                ('512 disk below floor',cases[5][1],524288,False,'below the project minimum floor'),
            ]:
                swaps.write_text('Filename Type Size Used Priority\n'+rows+'\n');mem.write_text(f'MemTotal: {ram} kB\nSwapTotal: 524288 kB\n')
                env=f'''MODE=disk; ALLOW_INTERNAL_DISK=0
INSTALL_MOUNTS=$PROC_MOUNTS; INSTALL_SWAPS=$PROC_SWAPS; INSTALL_SYS_CLASS_BLOCK=$SYS_CLASS_BLOCK
INSTALL_MEMINFO={shlex.quote(str(mem))}
log() {{ echo "$1"; }}; warn() {{ echo "WARN $1"; }}; err() {{ echo "ERROR $1"; exit 1; }}
'''
                p=subprocess.run(shell,input=pre+env+policy,text=True,capture_output=True)
                assert (p.returncode!=0)==reject and needle in p.stdout,(shell,label,p.returncode,p.stdout,p.stderr)
                total+=1
        print('PASS','/'.join(shell),'51 cross-consumer classifications + 9 installer policy cases',flush=True)
    print('All',total,'C1 scenarios passed.')


if __name__=='__main__': main()
