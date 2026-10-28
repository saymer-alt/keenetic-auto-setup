// Run the real offline UI with a small DOM/fetch fixture; no router or browser dependency.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

class Element {
 constructor(){this.children=[];this.style={};this.disabled=false;this.checked=false;this.value='';this.textContent='';this.files=[];this.handlers={};}
 replaceChildren(...children){this.children=children;}
 appendChild(child){this.children.push(child);child.parentElement=this;return child;}
 addEventListener(event,handler){this.handlers[event]=handler;}
 click(){if(!this.disabled)return this.handlers.click?.();}
 setAttribute(){}
 querySelectorAll(selector){const inputs=this.children.flatMap(label=>label.children||[]).filter(x=>x.type==='checkbox');return selector==='input:checked'?inputs.filter(x=>x.checked):inputs;}
}
const response=(status,data)=>({ok:status>=200&&status<300,status,json:async()=>data});
function ui(namesResult,inspectStatus=200,operationState='UNKNOWN',fixture={}){
 const ids=new Set([...fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8').matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]));
 const elements=new Map();
 const el=id=>{assert.ok(ids.has(id),'missing DOM element '+id);if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
 const requests=[];
 let homeOnly=false;
 const context=vm.createContext({
  document:{documentElement:{},getElementById:el,createElement:()=>new Element(),createTextNode:text=>({textContent:text})},
  localStorage:{getItem:()=>null},navigator:{language:'ru'},window:{confirm:()=>true},
  setTimeout:()=>1,clearTimeout(){},TextEncoder,
  fetch:async(url,options={})=>{
   requests.push({url,options});
   if(url==='/api/access'){
    if(options.method==='POST')homeOnly=JSON.parse(options.body).home_only;
    return response(200,{home_only:homeOnly});
   }
   if(url==='/api/filter/providers')return response(inspectStatus,{source_sha:'a'.repeat(64),providers:[{name:'P',http:true,has_filter:fixture.hasFilter!==false,existing_filter:fixture.hasFilter===false?'':'Old'}]});
   if(url==='/api/providers/names'){
    if(namesResult instanceof Error)throw namesResult;
    return namesResult;
   }
   if(url==='/api/filter/preview'&&fixture.beforePreview)await fixture.beforePreview();
   if(url==='/api/filter/preview')return fixture.previewFail?response(422,{error_code:'UNSUPPORTED_PROVIDER_YAML'}):response(200,{existing_filter:'Old',proposed_filter:JSON.parse(options.body||'null')?.clear?'':'New'});
   if(url==='/api/filter/apply')return response(202,{id:'operation',state:'RUNNING'});
   return response(200,{state:operationState});
  }
 });
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),context);
 return {el,requests,run:code=>vm.runInContext(code,context)};
}

for(const [label,namesResult] of [
 ['HTTP failure',response(502,{error_code:'MIHOMO_UNAVAILABLE'})],
 ['network failure',new Error('offline')],
 ['invalid JSON',{ok:true,json:async()=>{throw new Error('bad JSON');}}],
])test('clear remains available after names '+label,async()=>{
 const app=ui(namesResult);
 await app.run('loadFilterEditor()');
 assert.equal(app.el('filter-provider').value,'P');
 assert.equal(app.el('filter-clear').disabled,false);
 assert.equal(app.el('filter-preview').disabled,true);
 assert.match(app.el('filter-state').textContent,/снять|clear/i);
 await app.el('filter-clear').click();
 const request=app.requests.find(x=>x.url==='/api/filter/apply');
 assert.ok(request,'clear action did not apply');
 assert.deepEqual(JSON.parse(request.options.body),{provider:'P',names:[],clear:true,source_sha:'a'.repeat(64)});
});

test('failed inspection disables all changes even when names loaded',async()=>{
 const app=ui(response(200,{providers:{P:{proxies:[{name:'X'}]}}}),503);
 await app.run('loadFilterEditor()');
 for(const id of ['filter-clear','filter-preview'])assert.equal(app.el(id).disabled,true);
});

test('reloading after a names failure restores node selection',async()=>{
 let fail=true;
 const app=ui({ok:true,json:async()=>{if(fail)throw new Error('offline');return {providers:{P:{proxies:[{name:'X'}]}}};}});
 await app.run('loadFilterEditor()');
 assert.equal(app.el('filter-preview').disabled,true);
 fail=false;
 await app.run('loadFilterEditor()');
 assert.equal(app.el('filter-preview').disabled,false);
 assert.equal(app.el('filter-node-list').children[0].children[0].value,'X');
});

 test('successful import preserves the names-unavailable warning',async()=>{
 const app=ui(response(502,{error_code:'MIHOMO_UNAVAILABLE'}),200,'OK');
 await app.run('loadFilterEditor()');
 await app.el('filter-clear').click();
 await app.run('refreshImport()');
 assert.match(app.el('filter-state').textContent,/недоступны/);
 assert.doesNotMatch(app.el('filter-state').textContent,/Список узлов обновлён/);
});

test('Home-only checkbox defaults off and saves explicit user choice',async()=>{
 const app=ui(response(200,{providers:{}}));
 await new Promise(setImmediate); // let the real page's initial GET finish
 await app.run('refreshAccess()');
 assert.equal(app.el('access-home-only').checked,false);
 assert.equal(app.el('access-home-only').disabled,false);
 app.el('access-home-only').checked=true;
 await app.run('saveAccess()');
 assert.equal(app.el('access-home-only').checked,true);
 await app.run('refreshAccess()');
 assert.equal(app.el('access-home-only').checked,true);
 const request=app.requests.find(x=>x.url==='/api/access'&&x.options.method==='POST');
 assert.deepEqual(JSON.parse(request.options.body),{home_only:true});
 assert.equal(request.options.headers['X-KAS-Confirm'],'access');
 app.el('access-home-only').checked=false;
 await app.run('saveAccess()');
 assert.equal(app.el('access-home-only').checked,false);
});

test('exclude action previews then applies after confirmation without a separate apply button',async()=>{
 const app=ui(response(200,{providers:{P:{proxies:[{name:'X'}]}}}));
 await app.run('loadFilterEditor()');
 app.el('filter-node-list').children[0].children[0].checked=true;
 assert.equal(app.el('filter-preview').textContent,'Исключить выбранные');
 await app.el('filter-preview').click();
 const change=app.requests.find(x=>x.url==='/api/filter/apply');
 assert.ok(change,'exclude button did not apply the previewed change');
 assert.deepEqual(JSON.parse(change.options.body),{provider:'P',names:['X'],clear:false,source_sha:'a'.repeat(64)});
 const html=fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8');
 assert.doesNotMatch(html,/id="filter-apply"/);
});

test('cancel and preview error never start an importer',async()=>{
 for(const previewFail of [false,true]){
  const app=ui(response(200,{providers:{P:{proxies:[{name:'X'}]}}}),200,'UNKNOWN',{previewFail});
  await app.run('loadFilterEditor()');
  app.el('filter-node-list').children[0].children[0].checked=true;
  if(!previewFail)app.run('window.confirm=()=>false');
  await app.el('filter-preview').click();
  assert.equal(app.requests.some(x=>x.url==='/api/filter/apply'),false);
 }
});

test('clear is disabled when no filter exists',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{hasFilter:false});
 await app.run('loadFilterEditor()');
 assert.equal(app.el('filter-clear').disabled,true);
 await app.el('filter-clear').click();
 assert.equal(app.requests.some(x=>x.url==='/api/filter/preview'),false);
});

test('double-click does not submit duplicate filter operations',async()=>{
 const app=ui(response(200,{providers:{P:{proxies:[{name:'X'}]}}}));
 await app.run('loadFilterEditor()');
 app.el('filter-node-list').children[0].children[0].checked=true;
 await Promise.all([app.el('filter-preview').click(),app.el('filter-preview').click()]);
 assert.equal(app.requests.filter(x=>x.url==='/api/filter/apply').length,1);
});

test('asynchronous page changes cannot retarget the approved provider or source version',async()=>{
 let app;
 app=ui(response(200,{providers:{P:{proxies:[{name:'X'}]}}}),200,'UNKNOWN',{
  beforePreview:async()=>app.run("filterSelectedProvider='Q';filterInspect.source_sha='b'.repeat(64)")
 });
 await app.run('loadFilterEditor()');
 app.el('filter-node-list').children[0].children[0].checked=true;
 await app.el('filter-preview').click();
 const request=app.requests.find(x=>x.url==='/api/filter/apply');
 assert.ok(request);
 assert.deepEqual(JSON.parse(request.options.body),{provider:'P',names:['X'],clear:false,source_sha:'a'.repeat(64)});
});

 test('search preserves hidden selections and counts them in apply',async()=>{
 const app=ui(response(200,{providers:{P:{proxies:[{name:'Estonia Hy2'},{name:'Sweden Reality'}]}}}));
 await app.run('loadFilterEditor()');
 const list=app.el('filter-node-list');
 list.children[0].children[0].checked=true;
 app.el('filter-search').value='SWEDEN';
 await app.run('updateFilterSearch()');
 assert.equal(list.children[0].hidden,true);
 assert.equal(list.children[1].hidden,false);
 assert.match(app.el('filter-summary').textContent,/Выбрано: 1/);
 app.el('filter-search').value='no match';
 await app.run('updateFilterSearch()');
 assert.equal(app.el('filter-search-empty').hidden,false);
 await app.el('filter-preview').click();
 const request=app.requests.find(r=>r.url==='/api/filter/apply');
 assert.deepEqual(JSON.parse(request.options.body).names,['Estonia Hy2']);
});

test('completed and failed imports remain visible in the global operation banner',async()=>{
 for(const state of ['OK','FAIL']){
  const app=ui(response(200,{providers:{}}),200,state);
  await app.run('refreshImport()');
  assert.equal(app.el('operation-banner').hidden,false);
  assert.match(app.el('operation-message').textContent,state==='OK'?/успешно/:/ошибке/);
 }
});
