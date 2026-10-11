#!/usr/bin/env python3
"""Synthetic read-only architecture/resource admission, not hardware approval."""
import hashlib,json,os,pathlib,subprocess,tempfile
source=(pathlib.Path(__file__).resolve().parents[1]/'experimental/wdtt/service.sh').read_text()
functions=source[:source.index('ROOT=/opt/wdtt-experimental')]
for shell in [['sh'],['busybox','ash']]:
 for arch,head,machine in [('aarch64-3.10',(2,1,183,0),'aarch64'),('mipsel-3.4',(1,1,8,0),'mips')]:
  with tempfile.TemporaryDirectory(prefix='wdtt-admission-') as tmp:
   root=pathlib.Path(tmp)
   def put(name,text):
    p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(text if isinstance(text,bytes) else text.encode());return p
   data=bytearray(20);data[:4]=b'\x7fELF';data[4],data[5],data[18],data[19]=head
   elf=put('payload/wt-client',bytes(data));sha=hashlib.sha256(data).hexdigest()
   put('opt/bin/opkg',bytes(data));put('proc/net/udp','sl local_address remote st\n');put('proc/net/udp6','sl local_address remote st\n')
   put('proc/mounts',f'/dev/sda1 {root}/opt ext4 rw 0 0\ntmpfs /tmp tmpfs rw 0 0\n')
   put('proc/swaps','Filename Type Size Used Priority\n')
   mem=put('proc/meminfo','MemTotal: 800000 kB\nMemAvailable: 200000 kB\n')
   goarch='arm64' if arch.startswith('aarch64') else 'mipsle'
   provenance={'synthetic_fixture':True,'source':'1110a75f76e42c23149b8e24f9182c1ff179e515','toolchain':'go version go1.26.1 linux/amd64','install_ready':True,'license_gate':'APPROVED','builds':[{'arch':goarch,'sha256':sha,'pt_interp':False,'go_metadata':'GOMIPS=softfloat'}]}
   prov=put('payload/provenance.json',json.dumps(provenance))
   code=functions
   for prefix in ['/opt','/proc','/sys']:code=code.replace(prefix,str(root)+prefix)
   mock=f'''
id() {{ printf '%s\\n' 0; }}
uname() {{ printf '%s\\n' {machine}; }}
opkg() {{ printf '%s\\n' 'arch {arch} 10'; }}
df() {{ printf '%s\\n' 'Filesystem Blocks Used Available Capacity Mounted' '/dev/sda1 900000 100000 800000 12% /opt'; }}
admission "$1" "$2" "$3" "$4"
'''
   probe=put('probe.sh',code+mock)
   def run(ok=True,digest=sha,target=arch,port='19000'):
    p=subprocess.run(shell+[str(probe),str(elf),digest,target,port],capture_output=True,text=True,timeout=10)
    assert (p.returncode==0)==ok,(shell,arch,p.returncode,p.stderr)
   run();run(False,digest='0'*64);run(False,target='mips-3.4');run(False,port='70000')
   mem.write_text('MemTotal: 800000 kB\nMemFree: 150000 kB\n');run() # Linux 3.4 conservative fallback
   mem.write_text('MemTotal: 800000 kB\nMemAvailable: 20000 kB\n');run(False)
   mem.write_text('MemTotal: 120000 kB\nMemAvailable: 100000 kB\n');run(False)
   mem.write_text('MemTotal: 500000 kB\nMemAvailable: 200000 kB\n');run(False) # no verified backend
   mem.write_text('MemTotal: 800000 kB\nMemAvailable: 200000 kB\n')
   provenance['install_ready']=False;prov.write_text(json.dumps(provenance));run(False)
   provenance['install_ready']=True;prov.write_text(json.dumps(provenance))
   udp=root/'proc/net/udp';udp.write_text('sl local_address remote st\n0: 00000000:4A38 00000000:0000 07\n');run(False)
   udp.write_text('sl local_address remote st\n')
   # External unsupported FS and absence of actual /tmp tmpfs must fail closed.
   mount=root/'proc/mounts';saved=mount.read_text();mount.write_text(saved.replace('ext4','exfat'));run(False)
   mount.write_text(saved.replace('tmpfs /tmp tmpfs rw 0 0\n',''));run(False)
   mount.write_text(saved);run()
   saved_probe=probe.read_text();probe.write_text(saved_probe.replace('800000 12%', '1 12%'));run(False)
   probe.write_text(saved_probe)
   # Owner-local admission is separate from public APPROVED and stays fail-closed.
   init=put('init.d','synthetic init');installer=put('install.sh','synthetic installer')
   owner_probe=saved_probe.replace('admission "$1"', 'install_profile=owner-test\nadmission "$1"')
   probe.write_text(owner_probe)
   provenance.update(install_ready=False,license_gate='DEFERRED; NOT APPROVED',owner_local=True,
       owner_install_candidate=True,quarantine=False,public_distribution_approved=False,
       sdk_sha256='d51f30c126425ebff203b107a1a0aa9d3a5844f6c481bc6ff4c117cadc208674',
       lifecycle_sha256={'service.sh':hashlib.sha256(probe.read_bytes()).hexdigest(),
        'init.d':hashlib.sha256(init.read_bytes()).hexdigest(),'install.sh':hashlib.sha256(installer.read_bytes()).hexdigest()})
   prov.write_text(json.dumps(provenance));run()
   provenance['quarantine']=True;prov.write_text(json.dumps(provenance));run(False)
   provenance['quarantine']=False;provenance['lifecycle_sha256']['service.sh']='0'*64
   prov.write_text(json.dumps(provenance));run(False)
 print('PASS read-only admission:',shell,'ARM64/MIPSel ELF+opkg, SHA/softfloat metadata, RAM/backend/storage/tmpfs/port and closed provenance gates')
