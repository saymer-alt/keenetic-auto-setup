// The MagiTrickle updates empty state reused the Mihomo `updateNone`
// text, so a fresh panel claimed "Обновления Mihomo ещё не проверялись" under
// the MagiTrickle heading. This suite pins drawMTUpdates() to
// MagiTrickle-specific strings in every state and both languages. It is a pure
// DOM-stub harness: no fetch, no window.confirm, no updater action.
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
function segment(startMark,endMark){
 const start=source.indexOf(startMark),end=source.indexOf(endMark,start);
 assert.ok(start>=0&&end>start,'app.js segment not found: '+startMark);
 return source.slice(start,end);
}
const dictionaries=vm.runInNewContext('('+source.slice(source.indexOf('const words=')+'const words='.length,source.indexOf('\nlet lang=')).trim().replace(/;$/,'')+')');
const tBody=segment('const t=(key,params={})=>{','const set=');
const drawBody=segment('function drawMTUpdates(){','async function checkMTUpdates(){');
function harness(language){
 return vm.runInNewContext(
  'const words=dictionaries;let lang='+JSON.stringify(language)+';'+
  'const dom={},el=id=>dom[id]??(dom[id]={}),set=(id,value)=>{el(id).textContent=value;};'+
  'let mtCheckData=null,mtChecking=false,mtMessage="",updateOperation=null,updateMessage="",panelBusy=false,busy=false,importData=null,updateChecking=false,updateSubmitting=false;'+
  tBody+drawBody+
  ';({draw:drawMTUpdates,text:()=>dom["mt-state"]&&dom["mt-state"].textContent,'+
  'checkDisabled:()=>dom["mt-check"]&&dom["mt-check"].disabled,applyDisabled:()=>dom["update-mt"]&&dom["update-mt"].disabled,'+
  'state:{get mtCheckData(){return mtCheckData},set mtCheckData(v){mtCheckData=v},get mtChecking(){return mtChecking},set mtChecking(v){mtChecking=v},'+
  'get mtMessage(){return mtMessage},set mtMessage(v){mtMessage=v},get updateOperation(){return updateOperation},set updateOperation(v){updateOperation=v},'+
  'get updateMessage(){return updateMessage},set updateMessage(v){updateMessage=v}},setLang:v=>{lang=v}})',
  {dictionaries});
}
test('MagiTrickle empty state is its own bilingual string and never Mihomo text',()=>{
 for(const lang of ['ru','en']){
  assert.equal(typeof dictionaries[lang].mtNone,'string',lang+' mtNone missing');
  assert.notEqual(dictionaries[lang].mtNone,dictionaries[lang].updateNone);
  const h=harness(lang);h.draw();
  assert.equal(h.text(),dictionaries[lang].mtNone);
  assert.ok(h.text().includes('MagiTrickle'),lang+' empty state must name MagiTrickle');
  assert.ok(!h.text().includes('Mihomo'),lang+' empty state must not claim Mihomo');
 }
});
test('empty state follows the language toggle',()=>{
 const h=harness('ru');h.draw();
 assert.equal(h.text(),dictionaries.ru.mtNone);
 h.setLang('en');h.draw();
 assert.equal(h.text(),dictionaries.en.mtNone);
 h.setLang('ru');h.draw();
 assert.equal(h.text(),dictionaries.ru.mtNone);
});
test('pending, error, available and no-upgrade states keep MagiTrickle wording',()=>{
 const h=harness('ru');
 h.state.mtChecking=true;h.draw();
 assert.equal(h.text(),dictionaries.ru.mtChecking);assert.ok(h.text().includes('MagiTrickle'));
 assert.equal(h.checkDisabled(),true,'check is disabled while a check is running');
 h.state.mtChecking=false;h.state.mtMessage='CHECK_FAILED';h.draw();
 assert.equal(h.text(),'CHECK_FAILED');
 h.state.mtMessage='';
 h.state.mtCheckData={relation:'newer',current_version:'0.8.2-1',available_version:'0.8.3-1'};h.draw();
 assert.equal(h.text(),dictionaries.ru.mtAvailable.replace('{current}','0.8.2-1').replace('{available}','0.8.3-1'));
 assert.ok(!h.text().includes('Mihomo'));
 assert.equal(h.applyDisabled(),false);
 h.state.mtCheckData={relation:'no_upgrade',current_version:'0.8.2-1',available_version:'0.8.2-1'};h.draw();
 assert.equal(h.text(),dictionaries.ru.mtNoUpgrade.replace('{current}','0.8.2-1'));
 assert.equal(h.applyDisabled(),true,'no_upgrade must not enable the update button');
 for(const lang of ['en','ru']){
  const hl=harness(lang);hl.state.mtCheckData={relation:'newer',current_version:'0.8.2-1',available_version:'0.8.3-1'};hl.draw();
  assert.ok(!hl.text().includes('Mihomo'));
 }
});
test('magitrickle operation outcomes render; mihomo operations do not touch MT text',()=>{
 const h=harness('en');
 h.state.updateOperation={component:'mihomo',state:'RUNNING'};h.draw();
 assert.equal(h.text(),dictionaries.en.mtNone,'a running Mihomo update must not speak about MagiTrickle');
 h.state.updateOperation={component:'magitrickle',state:'RUNNING'};h.draw();
 assert.equal(h.text(),dictionaries.en.mtRunning);
 h.state.updateOperation={component:'magitrickle',state:'FAIL',error_code:'OPKG_LOCK'};h.draw();
 assert.equal(h.text(),dictionaries.en.mtFailed.replace('{code}','OPKG_LOCK'));
 h.state.updateOperation={component:'magitrickle',state:'OK',outcome:'CHANGED'};h.draw();
 assert.equal(h.text(),dictionaries.en.mtChanged);
 h.state.updateOperation={component:'magitrickle',state:'OK',outcome:'UNCHANGED'};h.draw();
 assert.equal(h.text(),dictionaries.en.mtUnchanged);
 h.state.updateMessage='STATUS_REPLACED';h.draw();
 assert.equal(h.text(),'STATUS_REPLACED');
});
test('drawMTUpdates only renders text and button state; it never acts',()=>{
 assert.ok(!drawBody.includes('fetch('),'must not network');
 assert.ok(!drawBody.includes('confirm('),'must not prompt');
 assert.ok(!drawBody.includes('checkMTUpdates')&&!drawBody.includes('startMTUpdate'),'must not invoke updaters');
});
