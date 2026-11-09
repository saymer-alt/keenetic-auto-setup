const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');

// The shared RU/EN dictionary object: const words={ ru:{...}, en:{...} };
const wordsEnd=source.indexOf('\n};')+2;
const wordsSource=source.slice(source.indexOf('const words={'),wordsEnd);
const words=vm.runInNewContext('('+wordsSource.slice(wordsSource.indexOf('{'))+')',{});

function harness({lang='ru',mtCheckData=null,mtChecking=false,mtMessage='',updateOperation=null,updateMessage='',updateChecking=false,updateSubmitting=false,busy=false,panelBusy=false,importData=null}={}){
 const nodes={};
 const el=id=>nodes[id]||(nodes[id]={textContent:'',disabled:false});
 const set=(id,value)=>{el(id).textContent=value;};
 const t=(key,params={})=>{
  let text=words[lang][key];
  if(text===undefined)return key;
  for(const [k,v] of Object.entries(params))text=text.replaceAll('{'+k+'}',v);
  return text;
 };
 const start=source.indexOf('function drawMTUpdates(){');
 const end=source.indexOf('\nasync function checkMTUpdates',start);
 const segment=source.slice(start,end);
 const state={panelBusy,busy,importData,updateOperation,updateSubmitting,updateChecking,mtChecking,mtCheckData,mtMessage,updateMessage};
 vm.runInNewContext(segment+';drawMTUpdates();',{...state,el,set,t,lang,words});
 return {el,nodes,state,words,lang};
}

test('RU/EN dictionaries keep identical key sets and a dedicated MagiTrickle empty-state key',()=>{
 assert.deepEqual(Object.keys(words.ru).sort(),Object.keys(words.en).sort());
 for(const lang of ['ru','en']){
  assert.ok(words[lang].mtNone,lang+' must define mtNone');
  assert.ok(words[lang].updateNone,lang+' must keep updateNone for the Mihomo section');
  assert.notEqual(words[lang].mtNone,words[lang].updateNone);
  assert.match(words[lang].mtNone,/MagiTrickle/);
  assert.doesNotMatch(words[lang].mtNone,/Mihomo/);
 }
 assert.match(words.ru.mtNone,/ещё не проверялись/);
 assert.match(words.en.mtNone,/have not been checked/);
});

test('empty MagiTrickle state names MagiTrickle in both languages and survives a language toggle',()=>{
 for(const lang of ['ru','en']){
  const app=harness({lang});
  assert.equal(app.nodes['mt-state'].textContent,app.words[lang].mtNone);
 }
});

test('checked, pending and operation states keep their existing keys and precedences',()=>{
 const available=harness({mtCheckData:{relation:'newer',current_version:'0.8.2-1',available_version:'0.8.3-1'}});
 assert.match(available.nodes['mt-state'].textContent,/0\.8\.2-1/);
 assert.equal(available.nodes['update-mt'].disabled,false);

 const noUpgrade=harness({mtCheckData:{relation:'no_upgrade',current_version:'0.8.2-1'}});
 assert.equal(noUpgrade.nodes['update-mt'].disabled,true);
 assert.match(noUpgrade.nodes['mt-state'].textContent,/0\.8\.2-1/);

 const pending=harness({mtChecking:true});
 assert.equal(pending.nodes['mt-state'].textContent,pending.words.ru.mtChecking);

 const failed=harness({updateOperation:{component:'magitrickle',state:'FAIL',error_code:'OPKG_FAILED'}});
 assert.match(failed.nodes['mt-state'].textContent,/OPKG_FAILED/);

 // A stale mtMessage must not resurrect the Mihomo empty-state text.
 const messaged=harness({mtMessage:'перезапуск подтверждён'});
 assert.equal(messaged.nodes['mt-state'].textContent,'перезапуск подтверждён');
});

test('drawMTUpdates never renders the Mihomo empty-state key for MagiTrickle',()=>{
 assert.ok(!source.includes("let text=t('updateNone')"),"drawMTUpdates must not use the Mihomo updateNone key");
 assert.ok(source.includes("let text=t('mtNone')"),'drawMTUpdates must use the dedicated mtNone key');
});
