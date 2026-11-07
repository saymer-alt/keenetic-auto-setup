#!/usr/bin/env python3
"""Host checks prove containment and conversion, not hardware/network safety."""
import base64,importlib.util,json,os,pathlib,subprocess,tempfile
base=pathlib.Path(__file__).resolve().parents[1]
exp=base/'experimental/wdtt'
spec=importlib.util.spec_from_file_location('convert',exp/'wg_to_mihomo.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
key=base64.b64encode(b'X'*32).decode()
conf=f'[Interface]\nPrivateKey = {key}\nAddress = 10.77.0.2/32\nDNS = 10.77.0.1\nMTU = 1280\n[Peer]\nPublicKey = {key}\nAllowedIPs = 0.0.0.0/0\nEndpoint = 127.0.0.1:9000\nPersistentKeepalive = 25\n'
out=m.convert(conf)
assert out['rules']==['MATCH,WDTT-LAB'] and 'tun' not in out and out['allow-lan'] is False
assert out['proxies'][0]['remote-dns-resolve'] is True and out['proxies'][0]['ip']=='10.77.0.2'
for invalid in [conf+'PostUp = ip route add default\n',conf.replace('127.0.0.1:9000','192.0.2.1:9000'),conf.replace('10.77.0.2/32','2001:db8::2/128'),conf+'[Peer]\n']:
    try:m.convert(invalid)
    except (ValueError,AssertionError,KeyError):pass
    else:raise AssertionError('unsafe conversion accepted')
with tempfile.TemporaryDirectory() as d:
    root=pathlib.Path(d);root.chmod(0o700);src=root/'wg.conf';src.write_text(conf);src.chmod(0o600);dst=root/'mihomo.json'
    cmd=['python3',str(exp/'wg_to_mihomo.py'),str(src),str(dst)]
    p=subprocess.run(cmd,capture_output=True,text=True);assert p.returncode==0 and key not in p.stdout+p.stderr
    assert dst.stat().st_mode&0o777==0o600
    saved=dst.read_bytes();p=subprocess.run(cmd,capture_output=True);assert p.returncode!=0 and dst.read_bytes()==saved
    dst.unlink();src.chmod(0o644);assert subprocess.run(cmd,capture_output=True).returncode!=0
    src.chmod(0o600);dst.symlink_to(src);assert subprocess.run(cmd,capture_output=True).returncode!=0
for shell in [['sh'],['busybox','ash']]:
    for name in ['preflight.sh','install.sh']:subprocess.run(shell+['-n',str(exp/name)],check=True)
    p=subprocess.run(shell+[str(exp/'install.sh')],capture_output=True,text=True);assert p.returncode==78
    assert 'BLOCKED' in p.stderr
    p=subprocess.run(shell+[str(exp/'install.sh'),'--plan'],capture_output=True,text=True);assert p.returncode==0
print('PASS: IPv4 config, tunnel DNS, no direct fallback, rejected injection/overwrite/symlink/public file, installer admission (dash + BusyBox)')
