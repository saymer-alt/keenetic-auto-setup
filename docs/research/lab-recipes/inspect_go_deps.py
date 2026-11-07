import hashlib,json,os,pathlib,subprocess
b=pathlib.Path(__file__).resolve().parent;env=os.environ.copy();env.update(GOOS='linux',GOARCH='arm64',CGO_ENABLED='0',GOTOOLCHAIN='local',GOPATH=str(b/'lab'/'gopath'),GOCACHE=str(b/'lab'/'gocache'))
p=subprocess.run(['go','list','-mod=readonly','-deps','-json','.'],cwd=b/'repos'/'hoaxisr__proxy-turn-vk-android'/'go_client',env=env,capture_output=True,text=True,encoding='utf-8',errors='replace');assert p.returncode==0,p.stderr
decoder=json.JSONDecoder();data=p.stdout;mods={};packages=[]
while data.strip():
    obj,n=decoder.raw_decode(data.lstrip());data=data.lstrip()[n:];packages.append(obj['ImportPath']);m=obj.get('Module')
    if m:mods[m['Path']]=m
records=[]
for path,m in sorted(mods.items()):
    d=pathlib.Path(m['Dir']);files=[]
    for f in d.iterdir():
        if f.is_file() and f.name.lower().startswith(('license','copying','notice')):
            t=f.read_text(encoding='utf-8',errors='replace');kind=[]
            for label,marker in [('MIT','Permission is hereby granted, free of charge'),('Apache-2.0','Apache License'),('BSD-style','Redistribution and use in source and binary forms'),('GPL','GNU GENERAL PUBLIC LICENSE'),('MPL','Mozilla Public License')]:
                if marker in t:kind.append(label)
            files.append({'file':f.name,'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'first_pass_text_markers':kind,'review':'Root text markers only; scope/version/vendor/exceptions require review'})
    records.append({'module':path,'version':m.get('Version'),'go_mod_sha256':hashlib.sha256(pathlib.Path(m['GoMod']).read_bytes()).hexdigest() if m.get('GoMod') else None,'licenses':files})
r={'target':'linux/arm64 CGO0','scope':'Actually imported Go dependency modules, root license file inventory; not legal compatibility approval or native/subdirectory audit','modules':records,'module_count':len(records),'go_lzo_imports':[x for x in packages if 'go-lzo' in x],'packages_count':len(packages)}
(b/'lab'/'wdtt'/'dependency-inventory.json').write_text(json.dumps(r,indent=2),encoding='utf-8');print(json.dumps({'modules':len(records),'missing_root_license':[x['module'] for x in records if not x['licenses']],'go_lzo_imports':r['go_lzo_imports']}))
