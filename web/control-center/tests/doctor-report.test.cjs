const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const api=require('../web/doctor-report.js');
const report=fs.readFileSync(path.join(__dirname,'fixtures/doctor-kn1010.txt'),'utf8');
const parse=(details=report,exit_code=0)=>api.parse({details,exit_code,summary:{verdict:exit_code===2?'FAIL':exit_code===1?'WARN':'OK',ok:37,warn:0,fail:0,info:65}});
test('real KN1010 report shape produces observed storage, memory and watchdog facts',()=>{
 const d=parse();assert.equal(d.supported,true);assert.equal(d.facts.model,'Giga (KN-1010)');
 assert.equal(d.facts.storage.class,'external');assert.equal(d.facts.storage.source,'/dev/sda2');
 assert.deepEqual(d.facts.opt,{free:14115,total:14190});assert.deepEqual(d.facts.ram,{free:68,total:248});
 assert.equal(d.facts.mihomo,'running');assert.equal(d.facts.magitrickle,'running');
 assert.equal(d.facts.heartbeats,19);assert.equal(d.facts.restarts,0);assert.equal(d.facts.rate_limits,0);
 assert.equal(d.facts.history.start,'2026-10-29 09:10:03');assert.deepEqual(d.findings,[]);
});
test('unknown, partial and mismatched Doctor reports never become a healthy overview',()=>{
 for(const text of [report.slice(0,-20),report.replace('1.2.19','9.0.0'),report+'trailing output',report.replace('WARN: 0','WARN: 1'),report+report,report.replace('===== 5. Service =====','===== 5. Service =====\n[WARN] Unexpected service state')])assert.equal(parse(text).supported,false);
 assert.equal(parse(report,1).supported,false);
 assert.equal(api.parse({details:report,exit_code:0,error_code:'TIMEOUT'}).supported,false);
});
test('missing or conflicting facts stay unknown rather than selecting a convenient value',()=>{
 for(const text of [report.replace('[INFO] RAM total: 248 MB, available: 68 MB',''),report.replace('available: 68 MB','available: 999 MB'),report.replace('[INFO] Swap:', '[INFO] RAM total: 248 MB, available: 67 MB\n[INFO] Swap:')])assert.equal(parse(text).facts.ram,undefined);
 assert.equal(parse(report.replace('14115 MB of 14190','15000 MB of 14190')).facts.opt,undefined);
 assert.equal(parse(report.replace('===== 1. System =====','===== 9. Network =====')).facts.storage,undefined);
});
test('CRLF/ANSI and supported older Doctor remain parseable',()=>{
 assert.equal(parse(report.replace(/\n/g,'\r\n').replace('[INFO] Doctor version:','\x1b[36m[INFO]\x1b[0m Doctor version:')).facts.os,'5.1.8');
 assert.equal(parse(report.replace('1.2.19','1.2.18')).supported,true);
});
test('warning evidence and unknown text survive without fabricating a provider diagnosis',()=>{
 const details=report.replace('===== 5. Service =====','===== 5. Service =====\n[WARN] Unknown future condition <img src=x onerror=alert(1)>').replace('WARN: 0','WARN: 1').replace('[OK] Overall status: OK','[WARN] Overall status: WARN');
 const d=api.parse({details,exit_code:1,summary:{verdict:'WARN',ok:37,warn:1,fail:0,info:65}});
 assert.equal(d.supported,true);assert.equal(d.findings.length,1);assert.equal(d.findings[0].severity,'WARN');assert.match(d.findings[0].evidence,/<img/);
 assert.equal(d.findings[0].section,'5');
});
test('watchdog events retain counts and never imply ISP failure',()=>{
 const d=parse(report.replace('[OK]   No restarts or problem detections in the available history','[INFO] Problem events on record: 2 restart(s), 3 rate-limited run(s) (problem detected, restart suppressed by cooldown)'));
 assert.equal(d.facts.restarts,2);assert.equal(d.facts.rate_limits,3);
 assert.equal(parse(report.replace('[OK]   No restarts or problem detections in the available history','')).facts.restarts,undefined);
});

test('renderer uses text nodes for untrusted evidence and complete RU/EN dictionaries',()=>{
 assert.deepEqual(Object.keys(api.labels.ru).sort(),Object.keys(api.labels.en).sort());
 class Node{constructor(doc){this.ownerDocument=doc;this.children=[];this.textContent='';}replaceChildren(){this.children=[];}appendChild(n){this.children.push(n);}set innerHTML(_){throw Error('HTML insertion forbidden');}}
 const doc={createElement:()=>new Node(doc)},container=new Node(doc);
 const details=report.replace('===== 5. Service =====','===== 5. Service =====\n[FAIL] <img src=x onerror=alert(1)>').replace('FAIL: 0','FAIL: 1').replace('[OK] Overall status: OK','[FAIL] Overall status: FAIL');
 api.render(container,{details,exit_code:2,summary:{verdict:'FAIL',ok:37,warn:0,fail:1,info:65}},'ru');
 const text=n=>[n.textContent,...n.children.map(text)].join(' ');
 assert.match(text(container),/Ошибка.*<img src=x onerror=alert\(1\)>/);
 assert.doesNotMatch(text(container),/ошибок и предупреждений нет/);
});

test('real pre-section process warning keeps its evidence in the readable report',()=>{
 const evidence='Multiple mihomo processes observed (2) - expected 1, possible stale leftovers';
 const details=report.replace('===== 1. System =====','[WARN] '+evidence+'\n\n===== 1. System =====').replace('WARN: 0','WARN: 1').replace('[OK] Overall status: OK','[WARN] Overall status: WARN');
 const d=api.parse({details,exit_code:1,summary:{verdict:'WARN',ok:37,warn:1,fail:0,info:65}});
 assert.equal(d.supported,true);assert.equal(d.findings.length,1);assert.equal(d.findings[0].evidence,evidence);
});
