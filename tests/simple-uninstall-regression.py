#!/usr/bin/env python3
"""Simple removal: stateful fixtures reused from the experimental removal tests."""
BASE_CONFIG = """interface Bridge0
    description Home
!
interface GigabitEthernet1
    rename ISP
    security-level public
    up
!
interface Proxy0
    description "mihomo t2s0"
    security-level public
{ip_global}
    proxy protocol socks5
    proxy upstream 127.0.0.1 7890
    proxy socks5-udp
    up
!
ip policy bypass_wa
    description bypass_wa
    permit global Proxy0
    no permit global GigabitEthernet1
!
dns-proxy
    intercept enable
!
"""

BASE_MANGLE = """-N _CUST_BYPASS_WA_
-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0xffffaaa/0xffffffff
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j CONNMARK --save-mark
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j RETURN
"""

FOREIGN_RULE = "-A PREROUTING -i Bridge0 -j MARK --set-xmark 0x1/0xffffffff"

OWNED_CRON = "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog\n"

FOREIGN_CRON = "17 3 * * * root /opt/lab/foreign-job\n"

NDMC = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
case "$2" in
'show running-config') tr -d '\\r' < "$S/running-config" ;;
'show ip policy') grep -A4 '^ip policy' "$S/running-config" || true ;;
'no ip policy bypass_wa')
    awk '
        /^ip policy bypass_wa$/ { skip=1; next }
        skip && /^!/ { skip=0; next }
        skip { next }
        { print }
    ' "$S/running-config" > "$S/running-config.new" && mv "$S/running-config.new" "$S/running-config"
    ;;
'no interface Proxy'*)
    _if=${2#no interface }
    awk -v ifn="$_if" '
        $0 == "interface " ifn { skip=1; next }
        skip && /^!/ { skip=0; next }
        skip { next }
        { print }
    ' "$S/running-config" > "$S/running-config.new" && mv "$S/running-config.new" "$S/running-config"
    ;;
'system configuration save') echo 'system configuration save' >> "$S/ndmc.log" ;;
*) exit 40 ;;
esac
"""

IPTABLES = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
spec="$*"
case "$spec" in
'-t mangle -S')
    cat "$S/mangle" ;;
'-t mangle -S _CUST_BYPASS_WA_')
    grep -q '^-N _CUST_BYPASS_WA_' "$S/mangle" || exit 1
    grep -E '^-N _CUST_BYPASS_WA_|^-A _CUST_BYPASS_WA_' "$S/mangle"
    ;;
'-t mangle -S PREROUTING')
    grep '^-A PREROUTING ' "$S/mangle"
    ;;
'-t mangle -F _CUST_BYPASS_WA_')
    grep -v '^-A _CUST_BYPASS_WA_' "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    ;;
'-t mangle -X _CUST_BYPASS_WA_')
    # real iptables refuses -X while the chain still holds rules
    grep -q '^-A _CUST_BYPASS_WA_' "$S/mangle" && exit 1
    grep -v '_CUST_BYPASS_WA_' "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    ;;
'-t mangle -D '*)
    target=$(printf '%s' "$spec" | sed 's/^-t mangle -D /-A /')
    grep -vF -- "$target" "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    ;;
*) exit 40 ;;
esac
"""

from pathlib import Path
import os, shutil, subprocess, tempfile, sys, time
BASE=Path(__file__).resolve().parents[1]
SHELLS=[['dash']]+([['busybox','ash']] if shutil.which('busybox') else [])
OPKG='''#!/bin/sh
S=$KAS_FAKE_STATE
echo "$*" >> "$S/opkg.log"
case "$1" in
list-installed) cat "$S/installed";;
status) cat "$S/status";;
remove)
 [ ! -f "$S/fail-opkg" ] || exit 1
 grep -v "^$2 " "$S/installed" > "$S/new"; mv "$S/new" "$S/installed"
 rm -f "$KAS_AUDIT_ROOT/opt/etc/mihomo/config.yaml" "$KAS_AUDIT_ROOT/opt/var/lib/magitrickle/config.yaml"
 ;;
*) exit 40;;
esac
'''
class Fixture:
 def __enter__(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='kas-simple-remove-')
  self.home=Path(self.tmp.name); self.root=self.home/'root'; self.state=self.home/'state'; self.bin=self.home/'bin'
  for d in (self.root,self.state,self.bin,self.root/'tmp'): d.mkdir(parents=True,exist_ok=True)
  self.write('.kas-uninstall-fixture','KAS_SIMPLE_REMOVE_TEST_V1\n')
  self.write('opt/etc/keenetic-auto-setup/ownership.v1','KAS_OWNERSHIP_V1\nowned|proxy|Proxy0\nowned|policy|bypass_wa\nowned|package|mihomo\nowned|package|magitrickle\nowned|watchdog|binary\nowned|watchdog|wrapper\nowned|hook|020-bypass_wa.sh\n')
  self.write('opt/bin/mihomo_watchdog.sh',(BASE/'mihomo-watchdog.sh').read_text())
  self.write('opt/etc/ndm/netfilter.d/020-bypass_wa.sh',(BASE/'020-bypass-wa.sh').read_text())
  self.write('opt/etc/cron.5mins/mihomo_watchdog','#!/bin/sh\nexec /opt/bin/mihomo_watchdog.sh "$@"\n')
  self.write('opt/etc/crontab',OWNED_CRON+FOREIGN_CRON)
  self.write('opt/etc/init.d/S99mihomo','#!/bin/sh\n\nENABLED=yes\nPROCS=mihomo\nARGS="-d /opt/etc/$PROCS"\nPREARGS=""\nDESC=$PROCS\nPATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n\n. /opt/etc/init.d/rc.func\n')
  self.write('opt/etc/mihomo/config.yaml','secret: DO_NOT_PRINT\n')
  self.write('opt/var/lib/magitrickle/config.yaml','secret: ALSO_PRIVATE\n')
  (self.state/'running-config').write_text(BASE_CONFIG.format(ip_global="    ip global 350")+'interface Proxy8\n    proxy upstream 192.0.2.8 8080\n!\n')
  (self.state/'mangle').write_text(BASE_MANGLE+FOREIGN_RULE+'\n')
  (self.state/'installed').write_text('mihomo - 1\nmagitrickle - 1\nforeign - 1\n')
  (self.state/'status').write_text('Package: mihomo\nStatus: install ok installed\n\nPackage: magitrickle\nStatus: install ok installed\n\nPackage: foreign\nStatus: install ok installed\n\n')
  for n,b in {'ndmc':NDMC,'iptables':IPTABLES,'opkg':OPKG}.items():
   p=self.bin/n; p.write_text(b); p.chmod(0o755)
  self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],KAS_AUDIT_ROOT=str(self.root),KAS_FAKE_STATE=str(self.state))
  return self
 def __exit__(self,*args): self.tmp.cleanup()
 def write(self,p,s):
  f=self.root/p; f.parent.mkdir(parents=True,exist_ok=True); f.write_text(s)
 def run(self,shell,answer='REMOVE\n'):
  p=subprocess.run(shell+[str(BASE/'uninstall.sh'),'--remove'],env=self.env,input=answer,text=True,capture_output=True,timeout=20)
  assert 'DO_NOT_PRINT' not in p.stdout+p.stderr and 'ALSO_PRIVATE' not in p.stdout+p.stderr
  return p
 def check_preserved(self):
  assert (self.root/'opt/etc/mihomo/config.yaml').read_text()=='secret: DO_NOT_PRINT\n'
  assert (self.root/'opt/var/lib/magitrickle/config.yaml').read_text()=='secret: ALSO_PRIVATE\n'
  assert 'Proxy8' in (self.state/'running-config').read_text()
  assert FOREIGN_RULE in (self.state/'mangle').read_text()
  assert FOREIGN_CRON in (self.root/'opt/etc/crontab').read_text()
  assert not list((self.root/'tmp').iterdir()), list((self.root/'tmp').iterdir())

for shell in SHELLS:
 with Fixture() as f:
  p=f.run(shell)
  assert p.returncode==0 and 'SUCCESS' in p.stdout,(p.returncode,p.stdout,p.stderr)
  assert 'bypass_wa' not in (f.state/'running-config').read_text()
  assert '_CUST_BYPASS_WA_' not in (f.state/'mangle').read_text()
  assert not (f.root/'opt/bin/mihomo_watchdog.sh').exists()
  assert (f.state/'installed').read_text()=='foreign - 1\n'
  f.check_preserved()
  p=f.run(shell)
  assert p.returncode==0 and 'SUCCESS' in p.stdout,(p.stdout,p.stderr)
  f.check_preserved()
 print('[PASS]',shell,'ordinary removal, repeat, foreign resources and YAML')

# Negative cases exercise actual command behavior, not a declared gate result.
for shell in SHELLS:
 for answer in ('','NO\n'):
  with Fixture() as f:
   before={p:str(p.read_bytes()) for p in f.root.rglob('*') if p.is_file()}
   p=f.run(shell,answer)
   assert p.returncode==3,(p.stdout,p.stderr)
   assert before=={p:str(p.read_bytes()) for p in f.root.rglob('*') if p.is_file()}
   assert (f.state/'installed').read_text().startswith('mihomo')
   f.check_preserved()
 with Fixture() as f:
  proc=subprocess.Popen([sys.executable,'-c',"import ctypes,time;ctypes.CDLL(None).prctl(15,b'mihomo',0,0,0);time.sleep(60)"])
  for _ in range(100):
   if Path(f'/proc/{proc.pid}/comm').read_text().strip()=='mihomo': break
   time.sleep(.01)
  try:
   p=f.run(shell)
   assert p.returncode==1 and '[LEFT] daemons' in p.stdout,(p.stdout,p.stderr)
   assert proc.poll() is None
   assert 'ENABLED=no' in (f.root/'opt/etc/init.d/S99mihomo').read_text()
   assert 'bypass_wa' in (f.state/'running-config').read_text()
   assert (f.state/'installed').read_text().startswith('mihomo')
   f.check_preserved()
  finally: proc.terminate();proc.wait()
 for kind in ('foreign-chain','foreign-cron','foreign-init','shared-dependency','modified-hook','yaml-link','fail-opkg'):
  with Fixture() as f:
   if kind=='foreign-chain':
    with (f.state/'mangle').open('a') as fp: fp.write('-A _CUST_BYPASS_WA_ -j DROP\n')
   if kind=='foreign-cron': f.write('opt/etc/crontab',OWNED_CRON+FOREIGN_CRON+'0 1 * * * root /opt/bin/mihomo -f /foreign.yaml\n')
   if kind=='foreign-init': f.write('opt/etc/init.d/S88foreign','#!/bin/sh\n/opt/bin/mihomo -f /foreign.yaml\n')
   if kind=='shared-dependency':
    with (f.state/'status').open('a') as fp: fp.write('Package: dependent\nStatus: install ok installed\nDepends: mihomo (>= 1)\n\n')
   if kind=='modified-hook': f.write('opt/etc/ndm/netfilter.d/020-bypass_wa.sh','#!/bin/sh\necho foreign\n')
   if kind=='yaml-link':
    p=f.root/'opt/etc/mihomo/config.yaml'; p.unlink();p.symlink_to(f.root/'opt/var/lib/magitrickle/config.yaml')
   if kind=='fail-opkg': (f.state/'fail-opkg').touch()
   p=f.run(shell)
   assert p.returncode==1,(kind,p.returncode,p.stdout,p.stderr)
   if kind in ('foreign-cron','foreign-init','shared-dependency','yaml-link','fail-opkg'):
    assert 'mihomo - 1' in (f.state/'installed').read_text(),(kind,p.stdout)
   if kind=='foreign-chain':
    assert '-j DROP' in (f.state/'mangle').read_text()
    assert (f.root/'opt/etc/ndm/netfilter.d/020-bypass_wa.sh').exists()
   if kind=='modified-hook': assert 'foreign' in (f.root/'opt/etc/ndm/netfilter.d/020-bypass_wa.sh').read_text()
   if kind=='fail-opkg': assert 'remove mihomo' not in (f.state/'opkg.log').read_text()
   if kind!='yaml-link': f.check_preserved()
 print('[PASS]',shell,'decline, EOF, live foreign process, shared resources and failure stop')

for shell in SHELLS:
 with Fixture() as f:
  # A previously interrupted removal can leave only chain rules.
  for path in ('opt/bin/mihomo_watchdog.sh','opt/etc/cron.5mins/mihomo_watchdog','opt/etc/init.d/S99mihomo','opt/etc/ndm/netfilter.d/020-bypass_wa.sh'):
   (f.root/path).unlink()
  f.write('opt/etc/crontab',FOREIGN_CRON)
  tool=f.bin/'iptables'
  tool.write_text(IPTABLES.replace('spec="$*"', 'spec="$*"\ncase "$spec" in *"-D _CUST_BYPASS_WA_ "*) exit 1;; esac'))
  p=f.run(shell)
  assert p.returncode==1 and '[PARTIAL]' in p.stdout,(p.stdout,p.stderr)
  assert '-A PREROUTING -m mark' not in (f.state/'mangle').read_text()
  assert 'bypass_wa' in (f.state/'running-config').read_text()
  f.check_preserved()
 print('[PASS]',shell,'partial netfilter failure reported honestly; dependent routes/packages retained')

for shell in SHELLS:
 with Fixture() as f:
  lock=f.root/'tmp/mihomo_watchdog.lock.d';lock.mkdir()
  (lock/'owner').write_text('unknown owner\n')
  before=(f.state/'running-config').read_text()
  p=f.run(shell)
  assert p.returncode==3 and 'Watchdog busy' in p.stderr,(p.stdout,p.stderr)
  assert (lock/'owner').read_text()=='unknown owner\n'
  assert (f.state/'running-config').read_text()==before
  assert (f.root/'opt/bin/mihomo_watchdog.sh').exists()
  (lock/'owner').unlink();lock.rmdir()
  f.check_preserved()
 with Fixture() as f:
  f.write('opt/etc/init.d/S99mihomo','#!/bin/sh\necho custom\n')
  p=f.run(shell)
  assert p.returncode==1 and '[LEFT] /opt/etc/init.d/S99mihomo' in p.stdout
  assert 'custom' in (f.root/'opt/etc/init.d/S99mihomo').read_text()
  assert 'mihomo - 1' in (f.state/'installed').read_text()
  f.check_preserved()
 print('[PASS]',shell,'foreign lock and modified init are retained')
# Reuse the existing lock implementation byte-for-byte.
source=(BASE/'uninstall-remove.sh').read_text()
reference=(BASE/'config-import.sh').read_text()
start='# BEGIN MIHOMO LIFECYCLE LOCK v1'; end='# END MIHOMO LIFECYCLE LOCK v1'
assert source.split(start)[1].split(end)[0]==reference.split(start)[1].split(end)[0]
assert not any(word in source for word in ('killall ', 'pkill ', 'kill -', 'eval ', 'rm -rf'))
print('[PASS] canonical lifecycle lock reused; no process signals or recursive deletion')

for shell in SHELLS:
 with Fixture() as f:
  with (f.state/'running-config').open('a') as cfg:
   cfg.write('interface Proxy9\n    proxy upstream 127.0.0.1 7890\n!\n')
  before=(f.root/'opt/etc/init.d/S99mihomo').read_text()
  p=f.run(shell)
  assert p.returncode==1
  assert (f.root/'opt/etc/init.d/S99mihomo').read_text()==before,'foreign proxy needs the shared service autostart'
  assert 'mihomo - 1' in (f.state/'installed').read_text()
  f.check_preserved()
 print('[PASS]',shell,'foreign Proxy sharing 7890 also preserves service autostart')
