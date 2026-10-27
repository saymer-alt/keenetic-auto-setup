import json, pathlib, socket, subprocess, threading, time
base=pathlib.Path(__file__).resolve().parent
lab=base/'lab';results={}
for arch,qemu in [('amd64',[]),('arm64',['qemu-aarch64']),('mipsle',['qemu-mipsel']),('mips',['qemu-mips'])]:
    p=subprocess.run(qemu+[str(lab/'wdtt'/f'wt-client-linux-{arch}'),'-h'],capture_output=True,text=True,timeout=30)
    results['wdtt-'+arch]={'rc':p.returncode,'help':p.stdout+p.stderr}
    p=subprocess.run(qemu+[str(lab/'wdtt'/f'wt-client-linux-{arch}'),'-awgm-protocol'],capture_output=True,text=True,timeout=30)
    results['protocol-'+arch]={'rc':p.returncode,'out':p.stdout+p.stderr}
for arch,qemu in [('amd64',[]),('arm64',['qemu-aarch64']),('mipsel',['qemu-mipsel']),('mips',['qemu-mips'])]:
    p=subprocess.run(qemu+[str(lab/'obfuscator'/f'wg-obfuscator-linux-{arch}'),'--help'],capture_output=True,text=True,timeout=30)
    results['obfuscator-'+arch]={'rc':p.returncode,'help':p.stdout+p.stderr}

echo=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);echo.bind(('127.0.0.1',0));echo.settimeout(0.2)
stop=threading.Event()
def serve():
    while not stop.is_set():
        try:
            data,addr=echo.recvfrom(8192)
            if data[:4]==b'\x01\x00\x00\x00':
                data=b'\x02\x00\x00\x00'+b'\x00'*88
            echo.sendto(data,addr)
        except socket.timeout:pass
t=threading.Thread(target=serve);t.start()
def free_port():
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',0));p=s.getsockname()[1];s.close();return p
client_port,server_port=free_port(),free_port()
exe=str(lab/'obfuscator'/'wg-obfuscator-linux-amd64');procs=[]
try:
    for port,target,mode in [(server_port,echo.getsockname()[1],'AUTO'),(client_port,server_port,'STUN')]:
        procs.append(subprocess.Popen([exe,'--source-if=127.0.0.1',f'--source-lport={port}',f'--target=127.0.0.1:{target}','--key=synthetic-lab-key',f'--masking={mode}','--verbose=DEBUG'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE))
    time.sleep(.5)
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.settimeout(3)
    sock.sendto(b'\x01\x00\x00\x00'+b'\x00'*144,('127.0.0.1',client_port))
    handshake_reply=sock.recv(8192)
    checks=[]
    for size in [32,148,512,1200,1420]:
        payload=b'\x04\x00\x00\x00'+bytes((i%251 for i in range(size-4)))
        sock.sendto(payload,('127.0.0.1',client_port))
        reply=sock.recv(8192)
        checks.append({'size':size,'equal':payload==reply})
    results['obfuscator-loopback']={'checks':checks,'synthetic_reply_type':handshake_reply[:4].hex(),'scope':'synthetic WireGuard-shaped headers and UDP echo through STUN/AUTO pair; no authenticated WireGuard handshake, no VK, no external network','initial_probe':'Uninitialized type-4 UDP echo timed out; state requires type-1/type-2 header sequence.'}
except Exception as e:
    results['obfuscator-loopback']={'error':str(e),'scope':'loopback only; failure is not hardware or network acceptance'}
finally:
    for p in procs:
        p.terminate()
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:p.kill();p.wait()
    results['obfuscator-loopback']['process_logs']=[p.stderr.read().decode(errors='replace') for p in procs]
    stop.set();t.join();echo.close()
(lab/'runtime.json').write_text(json.dumps(results,indent=2,ensure_ascii=False),encoding='utf-8')
print(json.dumps({k:({kk:vv for kk,vv in v.items() if kk!='help'}) for k,v in results.items()},ensure_ascii=False))
