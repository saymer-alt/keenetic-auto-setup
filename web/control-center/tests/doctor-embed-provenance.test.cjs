// #484 stage 3: Web embeds the Doctor as a build-time copy of the canonical
// root script (go:generate -> scripts/mihomo-doctor.sh -> go:embed), so the
// version a Web binary reports is the root script version at build time.
// Web beta.8 was built when that copy was 1.2.19 while Core v1.8.8 ships
// 1.2.22 — misleading in the field. No Web-side fork exists to sync; these
// guards keep it that way and refuse a build whose Doctor version the Web
// overview would refuse to summarize.
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
const cc=path.join(__dirname,'..'),repoRoot=path.join(cc,'../..');
const mainGo=fs.readFileSync(path.join(cc,'main.go'),'utf8');
const rootScript=fs.readFileSync(path.join(repoRoot,'mihomo-doctor.sh'),'utf8');
const parser=fs.readFileSync(path.join(cc,'web/doctor-report.js'),'utf8');
const gitignore=fs.readFileSync(path.join(cc,'.gitignore'),'utf8');
test('embedded Doctor is the generated root-script copy, never a hand-edited fork',()=>{
 assert.match(gitignore,/Generated only from the canonical root script\. Never edit this copy\./);
 assert.match(gitignore,/\/scripts\/mihomo-doctor\.sh/);
 assert.match(mainGo,/\/\/go:generate sh -c "[^"]*cp \.\.\/\.\.\/mihomo-doctor\.sh scripts\/mihomo-doctor\.sh/);
 assert.match(mainGo,/\/\/go:embed [^\n]*scripts\/mihomo-doctor\.sh/);
});
test('root Doctor version stays whitelisted by the Web report parser',()=>{
 const declared=rootScript.match(/^DOCTOR_VERSION="(\S+)"$/m);
 assert.ok(declared,'root script declares DOCTOR_VERSION');
 const set=parser.match(/const versions=new Set\(\[([^\]]*)\]\)/);
 assert.ok(set,'doctor-report.js declares the supported Doctor versions');
 const allowed=JSON.parse('['+set[1].replace(/'/g,'"')+']');
 assert.ok(allowed.includes(declared[1]),'embedded Doctor '+declared[1]+' must be accepted by doctor-report.js');
 const classify=parser.match(/report\.version!=='(\d+\.\d+\.\d+)'[^\n]*?(\d+\.\d+\.\d+)'[^\n]*?(\d+\.\d+\.\d+)'[^\n]*?(\d+\.\d+\.\d+)'/);
 if(classify)assert.ok(allowed.includes(classify[4]),'newest classifyWatchdogFinding version stays in the parse whitelist');
});
test('root Doctor emits the report lines the Web overview parses',()=>{
 assert.match(rootScript,/info "Doctor version: \$DOCTOR_VERSION"/);
 assert.match(rootScript,/info "KeeneticOS: \$_OS_TITLE"/);
});
