import json,pathlib,subprocess
b=pathlib.Path(__file__).resolve().parent;lab=b/'lab';records={}
def linux(p):return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def run(cmd):
    p=subprocess.run(cmd,capture_output=True,text=True,encoding='utf-8',errors='replace');return {'rc':p.returncode,'out':p.stdout,'err':p.stderr}
records['go_version']=run(['go','version']);records['kernel']=run(['wsl','-e','uname','-sr']);records['gcc']=run(['wsl','-e','gcc','--version'])
for arch in ['amd64','arm64','mipsle','mips']:
    p=lab/'wdtt'/('wt-client-linux-'+arch)
    records['wt-client-'+arch]={'elf':run(['wsl','-e','readelf','-h','-l','-A',linux(p)]),'go_buildinfo':run(['go','version','-m',str(p)])}
p=lab/'csqtt'/'target'/'release'/'client'
records['csqtt-amd64']={'elf':run(['wsl','-e','readelf','-h','-l','-d','-V',linux(p)]),'parser':run(['wsl','-e',linux(p),'--help'])}
(lab/'elf-probes.json').write_text(json.dumps(records,indent=2),encoding='utf-8');print(json.dumps({k:v.get('rc',v.get('elf',{}).get('rc')) for k,v in records.items()}))
