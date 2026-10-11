#!/usr/bin/env python3
"""Offline strict IPv4 conversion. JSON is accepted as YAML by Mihomo.
Never prints input, keys, exceptions, or a generated config to stdout/stderr.
"""
import argparse,base64,ipaddress,json,os,pathlib,stat,tempfile

def private_dir(p):
    p=pathlib.Path(p)
    if not p.is_absolute() or p.resolve()!=p or p.is_symlink():raise ValueError()
    s=p.stat()
    if not stat.S_ISDIR(s.st_mode) or stat.S_IMODE(s.st_mode)!=0o700 or s.st_uid!=os.geteuid():raise ValueError()
def read_private(p):
    p=pathlib.Path(p);private_dir(p.parent)
    fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as f:
        s=os.fstat(f.fileno())
        if not stat.S_ISREG(s.st_mode) or stat.S_IMODE(s.st_mode)!=0o600 or s.st_uid!=os.geteuid() or s.st_nlink!=1:raise ValueError()
        b=f.read(65537)
        if len(b)>65536:raise ValueError()
        return b.decode('utf-8')
def convert(text,port=9000):
    sections={};current=None
    for raw in text.splitlines():
        line=raw.strip()
        if not line or line.startswith('#'):continue
        if line.startswith('['):
            if line not in ('[Interface]','[Peer]') or line in sections:raise ValueError()
            current={};sections[line]=current;continue
        if current is None or '=' not in line:raise ValueError()
        k,v=map(str.strip,line.split('=',1))
        if k in current:raise ValueError()
        current[k]=v
    i,p=sections['[Interface]'],sections['[Peer]']
    if set(i)-{'PrivateKey','Address','DNS','MTU'} or set(p)-{'PublicKey','PresharedKey','Endpoint','AllowedIPs','PersistentKeepalive'}:raise ValueError()
    if p['Endpoint']!='127.0.0.1:'+str(port):raise ValueError()
    ip=ipaddress.ip_interface(i['Address']);assert ip.version==4
    for k in [i['PrivateKey'],p['PublicKey']]+([p['PresharedKey']] if 'PresharedKey' in p else []):
        if len(base64.b64decode(k,validate=True))!=32:raise ValueError()
    allowed=[str(ipaddress.ip_network(x.strip(),strict=False)) for x in p['AllowedIPs'].split(',')]
    if any(ipaddress.ip_network(x).version!=4 for x in allowed):raise ValueError()
    dns=[str(ipaddress.IPv4Address(x.strip())) for x in i['DNS'].split(',')]
    if not dns:raise ValueError()
    mtu=int(i.get('MTU','1280'));keep=int(p.get('PersistentKeepalive','25'))
    if not 576<=mtu<=1420 or not 0<=keep<=65535:raise ValueError()
    outbound={'name':'WDTT-LAB','type':'wireguard','server':'127.0.0.1','port':port,'ip':str(ip.ip),'private-key':i['PrivateKey'],'public-key':p['PublicKey'],'allowed-ips':allowed,'mtu':mtu,'persistent-keepalive':keep,'udp':True,'remote-dns-resolve':True,'dns':dns}
    if 'PresharedKey' in p:outbound['pre-shared-key']=p['PresharedKey']
    return {'mixed-port':17890,'bind-address':'127.0.0.1','allow-lan':False,'ipv6':False,'mode':'rule','log-level':'silent','dns':{'enable':False},'proxies':[outbound],'rules':['MATCH,WDTT-LAB']}
def main():
    p=argparse.ArgumentParser();p.add_argument('input');p.add_argument('output');p.add_argument('--port',type=int,default=9000);a=p.parse_args()
    try:
        if not 1<=a.port<=65535:raise ValueError()
        result=convert(read_private(a.input),a.port)
        dst=pathlib.Path(a.output);private_dir(dst.parent)
        # Never overwrite the existing Mihomo/KAS configuration or any file.
        if dst.exists() or dst.is_symlink():raise ValueError()
        fd,tmp=tempfile.mkstemp(prefix='.mihomo-stage-',dir=dst.parent)
        try:
            with os.fdopen(fd,'w') as f:json.dump(result,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
            os.link(tmp,dst) # atomic, fails if any destination appears concurrently
        finally:os.unlink(tmp)
    except Exception:
        raise SystemExit('WDTT_CONVERSION_REJECTED') from None
    print('WDTT_PRIVATE_CONFIG_CREATED')
if __name__=='__main__':main()
