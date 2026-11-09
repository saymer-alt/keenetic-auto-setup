// Issue #476 stage B: the Entware /opt storage card in the Diagnostics view
// renders the additive `storage` block of the SAME one-shot metrics snapshot
// (no new request, no polling), with honest UNKNOWN/N-A handling, MiB units
// with overflow guards, textContent-only output and RU/EN parity.
// Pure DOM-stub harness: no fetch, no timers, no real DOM.
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const html=fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8');
function segment(startMark,endMark){
 const start=source.indexOf(startMark),end=source.indexOf(endMark,start);
 assert.ok(start>=0&&end>start,'app.js segment not found: '+startMark);
 return source.slice(start,end);
}
const dictionaries=vm.runInNewContext('('+source.slice(source.indexOf('const words=')+'const words='.length,source.indexOf('\nlet lang=')).trim().replace(/;$/,'')+')');
const tBody=segment('const t=(key,params={})=>{','const set=');
const drawBody=segment('function drawOptStorage(){','async function readRouterMetrics(){');
const els={};
function harness(language){
 return vm.runInNewContext(
  'const words=dictionaries;let lang='+JSON.stringify(language)+';'+
  'const el=id=>els[id]??(els[id]={textContent:"",hidden:false,children:[],replaceChildren(){this.children=[]},append(...n){this.children.push(...n)}});'+
  'const set=(id,value)=>{el(id).textContent=value;};'+
  'const document={createElement:tag=>({tag,textContent:"",children:[],append(...n){this.children.push(...n)}})};'+
  'let metricsBusy=false,metricsError="",metricsData=null;'+
  tBody+drawBody+
  ';({draw:drawOptStorage,els,'+
  'state:{get metricsBusy(){return metricsBusy},set metricsBusy(v){metricsBusy=v},get metricsError(){return metricsError},set metricsError(v){metricsError=v},get metricsData(){return metricsData},set metricsData(v){metricsData=v}},'+
  'setLang:v=>{lang=v},t})',
  {dictionaries,els});
}
const unknownOf=lang=>dictionaries[lang].metricsUnknown;
// KN-3811 field profile mirrored by the stage A shell fixture
// internal_ubifs_root_mount_kn3811: /opt lives on the internal UBIFS rootfs.
const UBIFS={status:'PASS',path:'/opt',mount_class:'internal',fstype:'ubifs',mount_point:'/',free_kb:'49152',total_kb:'100352',source:'df+proc_mounts',observed_utc:'2026-11-09T21:30:00Z',note:'filesystem-level df capacity of the /opt filesystem, not raw flash size'};
const EXT4={status:'PASS',path:'/opt',mount_class:'external',fstype:'ext4',mount_point:'/tmp/mnt/Store One',free_kb:'19456',total_kb:'20480',source:'df+proc_mounts',observed_utc:'2026-11-09T21:30:00Z',note:'filesystem-level df capacity of the /opt filesystem, not raw flash size'};
function rows(h){
 return h.els['opt-values'].children.map(cell=>({label:cell.children[0].textContent,value:cell.children[1].textContent}));
}
function valueOf(h,label){
 const row=rows(h).find(r=>r.label===label);
 return row?row.value:null;
}
test('card markup exists and starts hidden with no new scripts or timers',()=>{
 for(const id of ['opt-heading','opt-help','opt-state','opt-values'])assert.match(html,new RegExp('id="'+id+'"'),'index.html missing '+id);
 assert.match(html,/id="opt-values"[^>]*hidden/,'/opt values must start hidden');
 assert.equal((html.match(/<script/g)||[]).length,(fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8').match(/<script/g)||[]).length,'no new script tags');
 // one-shot only: the storage renderer never networks and never polls.
 for(const forbidden of ['fetch(','setInterval(','setTimeout(','XMLHttpRequest','EventSource'])
  assert.ok(!drawBody.includes(forbidden),'drawOptStorage must not contain '+forbidden);
 // same one-shot request: draw() calls the renderer right after drawMetrics().
 assert.match(source,/drawMetrics\(\);\s*drawOptStorage\(\);/);
});
test('KN-3811 internal UBIFS profile: free/total MiB, internal class, root mount point, no percent',()=>{
 for(const lang of ['ru','en']){
  const h=harness(lang);h.state.metricsData={storage:UBIFS};h.draw();
  assert.equal(h.els['opt-state'].textContent,dictionaries[lang].optReady);
  assert.equal(h.els['opt-values'].hidden,false);
  assert.equal(valueOf(h,dictionaries[lang].optFreeTotal),'48.0 MiB / 98.0 MiB');
  assert.equal(valueOf(h,dictionaries[lang].optClass),dictionaries[lang].optClassInternal);
  assert.equal(valueOf(h,dictionaries[lang].optFstype),'ubifs');
  assert.equal(valueOf(h,dictionaries[lang].optMountPoint),'/');
  const all=rows(h).map(r=>r.value).join(' | ')+h.els['opt-state'].textContent;
  assert.ok(!all.includes('%'),'no fabricated percent/severity: '+all);
  assert.ok(!/overheat|перегрев|FAIL|WARN/i.test(all),'no health verdict: '+all);
 }
});
test('external EXT4 profile shows the external class and decoded mount point',()=>{
 const h=harness('ru');h.state.metricsData={storage:EXT4};h.draw();
 assert.equal(valueOf(h,dictionaries.ru.optFreeTotal),'19.0 MiB / 20.0 MiB');
 assert.equal(valueOf(h,dictionaries.ru.optClass),dictionaries.ru.optClassExternal);
 assert.equal(valueOf(h,dictionaries.ru.optMountPoint),'/tmp/mnt/Store One');
 assert.equal(valueOf(h,dictionaries.ru.optFstype),'ext4');
});
test('PASS with unknown mount class (ambiguous mounts, source df) shows numbers without internal/external claim',()=>{
 // Stage A design (docs/30-sys-metrics.md): conflicting equally deep mount
 // entries keep df capacity as honest PASS but classify as unknown. The card
 // must show free/total and must NOT claim internal or external storage.
 const ambiguous={status:'PASS',path:'/opt',mount_class:'unknown',fstype:'unknown',mount_point:'unknown',free_kb:'49152',total_kb:'100352',source:'df',observed_utc:'2026-11-09T21:30:00Z',note:'...equally deep conflicting mount entries...'};
 const h=harness('ru');h.state.metricsData={storage:ambiguous};h.draw();
 assert.equal(valueOf(h,dictionaries.ru.optFreeTotal),'48.0 MiB / 98.0 MiB');
 const classValue=valueOf(h,dictionaries.ru.optClass);
 assert.equal(classValue,unknownOf('ru'));
 assert.notEqual(classValue,dictionaries.ru.optClassInternal);
 assert.notEqual(classValue,dictionaries.ru.optClassExternal);
 assert.equal(valueOf(h,dictionaries.ru.optFstype),unknownOf('ru'));
});
test('UNKNOWN never fabricates numbers or zeros; retained classification stays visible',()=>{
 // garbled_df_unknown_class_retained stage A fixture: capacity unknown, but
 // the mount classification (internal/ubifs) is still known and is shown.
 const garbled={status:'UNKNOWN',path:'/opt',mount_class:'internal',fstype:'ubifs',mount_point:'/opt',free_kb:'',total_kb:'',source:'proc_mounts',observed_utc:'2026-11-09T21:30:00Z',note:'no reliable /opt filesystem capacity observation; ...'};
 const h=harness('en');h.state.metricsData={storage:garbled};h.draw();
 assert.equal(h.els['opt-state'].textContent,unknownOf('en'));
 const values=rows(h).map(r=>r.value).join(' | ');
 assert.ok(!values.includes('MiB'),'no numbers on UNKNOWN: '+values);
 assert.ok(!/\b0\b MiB/.test(values),'no fabricated zeros');
 assert.equal(valueOf(h,dictionaries.en.optFreeTotal),unknownOf('en'));
 assert.equal(valueOf(h,dictionaries.en.optClass),dictionaries.en.optClassInternal);
});
test('N/A is distinct from UNKNOWN and renders no rows',()=>{
 const h=harness('ru');h.state.metricsData={storage:{status:'N/A',path:'/opt',mount_class:'unknown',fstype:'unknown',mount_point:'unknown',free_kb:'',total_kb:'',source:'none',observed_utc:'2026-11-09T21:30:00Z',note:'no reliable /opt filesystem capacity observation'}};
 h.draw();
 assert.equal(h.els['opt-state'].textContent,dictionaries.ru.optNa);
 assert.notEqual(dictionaries.ru.optNa,unknownOf('ru'),'N/A and UNKNOWN must use distinct texts');
 assert.equal(h.els['opt-values'].hidden,true,'no rows for N/A');
 assert.equal(h.els['opt-values'].children.length,0);
});
test('old 0.1.0 collector responses without storage stay valid and honest',()=>{
 const h=harness('en');h.state.metricsData={schema:'router-metrics/v1',tool:'kas-sys-metrics.sh',tool_version:'0.1.0',temperature:{status:'PASS'},load:{status:'PASS'},uptime:{status:'PASS'},memory:{status:'PASS'},swap:{status:'INFO'}};h.draw();
 assert.equal(h.els['opt-state'].textContent,dictionaries.en.optUnavailable);
 assert.equal(h.els['opt-values'].hidden,true);
 assert.equal(h.els['opt-values'].children.length,0);
});
test('zero free space is an honest PASS, not a zero-substituted unknown',()=>{
 const h=harness('ru');h.state.metricsData={storage:{...UBIFS,free_kb:'0'}};h.draw();
 assert.equal(valueOf(h,dictionaries.ru.optFreeTotal),'0.0 MiB / 98.0 MiB');
 assert.equal(h.els['opt-state'].textContent,dictionaries.ru.optReady);
});
test('huge and malformed numbers are rejected before rendering',()=>{
 const h=harness('en');
 for(const storage of [
  {...UBIFS,free_kb:'12345678901'},              // 11 digits: outside the 1..10 bound
  {...UBIFS,free_kb:'99999999999',total_kb:'99'},// free > total
  {...UBIFS,free_kb:'-100'},                     // negative
  {...UBIFS,free_kb:'12.5'},                     // fractional
  {...UBIFS,free_kb:'abc'},                      // non-numeric
  {...UBIFS,total_kb:'0'},                       // zero total
  {...UBIFS,free_kb:''},                         // missing number on PASS
  {...UBIFS,free_kb:'49152',total_kb:''},        // missing total on PASS
 ]){
  h.state.metricsData={storage};h.draw();
  assert.equal(valueOf(h,dictionaries.en.optFreeTotal),unknownOf('en'),'digits must not render for '+JSON.stringify(storage.free_kb)+'/'+storage.total_kb);
  assert.equal(h.els['opt-state'].textContent,unknownOf('en'),'non-PASS-guaranteed state for '+JSON.stringify(storage.free_kb));
 }
});
test('control bytes and XSS payloads are never interpreted as markup',()=>{
 const h=harness('ru');
 const hostile={...UBIFS,mount_point:'<script>alert(1)</script>',fstype:'ub\x01fs',note:'\u0001bad'};
 h.state.metricsData={storage:hostile};h.draw();
 assert.equal(valueOf(h,dictionaries.ru.optMountPoint),'<script>alert(1)</script>','textContent only, literal string');
 assert.equal(valueOf(h,dictionaries.ru.optFstype),unknownOf('ru'),'control byte in fstype rejected');
 const bytes={...UBIFS,mount_point:'/opt\u0001evil'};
 h.state.metricsData={storage:bytes};h.draw();
 assert.equal(valueOf(h,dictionaries.ru.optMountPoint),unknownOf('ru'),'control byte in mount point rejected');
 assert.ok(!drawBody.includes('innerHTML'),'renderer must not use innerHTML');
});
test('observed_utc renders the snapshot time; malformed and unknown stay honest',()=>{
 const h=harness('en');
 h.state.metricsData={storage:UBIFS};h.draw();
 const rendered=valueOf(h,dictionaries.en.optObserved);
 assert.ok(rendered!=='unknown'&&rendered.includes('2026'),'localized snapshot time: '+rendered);
 h.state.metricsData={storage:{...UBIFS,observed_utc:'unknown'}};h.draw();
 assert.equal(valueOf(h,dictionaries.en.optObserved),'unknown');
 h.state.metricsData={storage:{...UBIFS,observed_utc:'not-a-date'}};h.draw();
 assert.equal(valueOf(h,dictionaries.en.optObserved),unknownOf('en'));
 h.state.metricsData={storage:{...UBIFS,observed_utc:'2026-11-09T21:30:00Z; DROP'}};h.draw();
 assert.equal(valueOf(h,dictionaries.en.optObserved),unknownOf('en'));
});
test('before the first request the card shows its own not-requested text, then mirrors busy and error states',()=>{
 const h=harness('ru');h.draw();
 assert.equal(h.els['opt-state'].textContent,dictionaries.ru.optNone);
 assert.equal(h.els['opt-values'].hidden,true);
 h.state.metricsBusy=true;h.draw();
 assert.equal(h.els['opt-state'].textContent,dictionaries.ru.metricsLoading);
 h.state.metricsBusy=false;h.state.metricsError='HTTP_503';h.draw();
 assert.equal(h.els['opt-state'].textContent,dictionaries.ru.metricsError.replace('{code}','HTTP_503'));
});
test('language toggle re-renders the card without re-request',()=>{
 const h=harness('ru');h.state.metricsData={storage:UBIFS};h.draw();
 assert.equal(h.els['opt-heading'].textContent,dictionaries.ru.optHeading);
 assert.equal(valueOf(h,dictionaries.ru.optFreeTotal),'48.0 MiB / 98.0 MiB');
 h.setLang('en');h.draw();
 assert.equal(h.els['opt-heading'].textContent,dictionaries.en.optHeading);
 assert.equal(valueOf(h,dictionaries.en.optClass),dictionaries.en.optClassInternal);
 h.setLang('ru');h.draw();
 assert.equal(h.els['opt-heading'].textContent,dictionaries.ru.optHeading);
});
test('RU/EN word parity for every storage key',()=>{
 const keys=['optHeading','optHelp','optNone','optUnavailable','optNa','optReady','optFreeTotal','optClass','optClassInternal','optClassExternal','optClassRam','optFstype','optMountPoint','optObserved'];
 for(const key of keys){
  assert.equal(typeof dictionaries.ru[key],'string','ru missing '+key);
  assert.equal(typeof dictionaries.en[key],'string','en missing '+key);
 }
 // the RAM class label is wired and honest even though it only appears on
 // tmpfs/ramfs mounts
 assert.ok(dictionaries.ru.optClassRam.includes('tmpfs'));
 assert.ok(dictionaries.en.optClassRam.includes('tmpfs'));
 assert.ok(dictionaries.ru.optHelp.includes('/tmp')&&dictionaries.ru.optHelp.includes('swap'),'RU help must disclaim RAM/swap//tmp confusion');
 assert.ok(dictionaries.en.optHelp.includes('/tmp')&&dictionaries.en.optHelp.includes('swap'),'EN help must disclaim RAM/swap//tmp confusion');
});
test('RAM-backed tmpfs mount reports the RAM class, not flash',()=>{
 const h=harness('ru');h.state.metricsData={storage:{status:'PASS',path:'/opt',mount_class:'ram',fstype:'tmpfs',mount_point:'/opt',free_kb:'1024',total_kb:'1024',source:'df+proc_mounts',observed_utc:'2026-11-09T21:30:00Z',note:'...'}};
 h.draw();
 assert.equal(valueOf(h,dictionaries.ru.optClass),dictionaries.ru.optClassRam);
 assert.equal(valueOf(h,dictionaries.ru.optFreeTotal),'1.0 MiB / 1.0 MiB');
});
