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
 const requests=[],stored=[];
 let settings=fixture.settings||{port:18081,auth_mode:'none',login:'',password_set:false};
 let homeOnly=false;
 const context=vm.createContext({
  document:{documentElement:{setAttribute(name,value){this[name]=value;}},getElementById:el,createElement:()=>new Element(),createTextNode:text=>({textContent:text})},
  localStorage:{getItem:key=>{if(fixture.storageFail)throw Error('storage unavailable');return key==='kas_theme'?fixture.theme||null:null;},setItem:(...args)=>{if(fixture.storageFail)throw Error('storage unavailable');stored.push(args);}},navigator:{language:'ru'},window:{confirm:()=>true,location:{href:fixture.href||'http://router.test:18081/'}},URL,
  setTimeout:()=>1,clearTimeout(){},TextEncoder,
  fetch:async(url,options={})=>{
   requests.push({url,options});
   if(url==='/api/updates/check')return response(200,fixture.updateCheck||{state:'AVAILABLE',available_version:'1.20.0',current_version:'1.19.33',package_release:2,relation:'newer'});
   if(url==='/api/updates/mihomo'&&fixture.updatePostError)throw Error('response lost');
   if(url==='/api/updates/mihomo')return response(202,{id:'update-op',state:'RUNNING'});
   if(url==='/api/updates/magitrickle/check')return response(200,fixture.mtCheck||{state:'AVAILABLE',current_version:'0.8.2-1',available_version:'0.8.2-2',relation:'newer'});
   if(url==='/api/updates/magitrickle'&&fixture.mtPostError)throw Error('response lost');
   if(url==='/api/updates/magitrickle')return response(202,{id:'mt-op',component:'magitrickle',state:'RUNNING'});
   if(url==='/api/updates/operation')return response(200,fixture.updateOperation||{state:'UNKNOWN',error_code:'NO_OPERATION'});
   if(url==='/api/components')return response(200,fixture.components||{panel:{version:'development',source_sha:''},core:{state:'absent'},watchdog:{state:'unrecorded'}});
   if(url==='/api/settings'){
    if(fixture.settingsFail)return response(503,{error_code:'SETTINGS_READ_FAILED'});
    if(options.method==='POST'){
     if(fixture.settingsPost)return fixture.settingsPost;
     const body=JSON.parse(options.body);settings={port:body.port,auth_mode:body.auth_mode,login:({none:'',panel:'kas',entware:'root'})[body.auth_mode],password_set:body.auth_mode!=='none'};
     return response(200,{...settings,url:'http://router.test:'+settings.port});
    }
    return response(200,settings);
   }
   if(url==='/api/access'){
    if(options.method==='POST')homeOnly=JSON.parse(options.body).home_only;
    return response(200,{home_only:homeOnly});
   }
   if(url==='/api/filter/providers')return response(inspectStatus,fixture.inspectError?{error_code:fixture.inspectError}:{source_sha:'a'.repeat(64),providers:[{name:'P',http:true,has_filter:fixture.hasFilter!==false,existing_filter:fixture.hasFilter===false?'':'Old'}]});
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
 const reportPath=path.join(__dirname,'../web/doctor-report.js');if(fs.existsSync(reportPath))vm.runInContext(fs.readFileSync(reportPath,'utf8'),context);
 const themePath=path.join(__dirname,'../web/theme.js');if(fs.existsSync(themePath))vm.runInContext(fs.readFileSync(themePath,'utf8'),context);
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),context);
 return {el,requests,stored,run:code=>vm.runInContext(code,context)};
}

test('Doctor copies the full report through the modern clipboard API',async()=>{
 const app=ui(response(200,{providers:{}}));
 await new Promise(setImmediate);
 app.run(`doctorData={details:'Doctor\\nОтчёт\\n'};navigator.clipboard={writeText:async text=>{globalThis.copied=text;}};draw();`);
 await app.el('copy').click();
 assert.equal(app.run('copied'),'Doctor\nОтчёт\n');
 assert.match(app.el('copy-state').textContent,/скопирован/i);
});

for(const modern of ['absent','denied'])test('Doctor falls back when modern clipboard is '+modern,async()=>{
 const app=ui(response(200,{providers:{}}));
 await new Promise(setImmediate);
 app.run(`
 doctorData={details:'Doctor\\nОтчёт\\n'};
 globalThis.area=null;globalThis.removed=false;
 document.body={appendChild:node=>{globalThis.area=node;}};
 document.createElement=()=>({style:{},setAttribute(){},select(){},remove(){globalThis.removed=true;}});
 document.execCommand=command=>{if(command==='copy'){globalThis.copied=area.value;return true;}return false;};
 `);
 app.run('draw()');
 if(modern==='denied')app.run(`navigator.clipboard={writeText:async()=>{throw Error('Denied');}};`);
 await app.el('copy').click();
 assert.equal(app.run('copied'),'Doctor\nОтчёт\n');
 assert.equal(app.run('removed'),true);
 assert.match(app.el('copy-state').textContent,/скопирован/i);
});

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

test('historical completed imports do not resurrect the global banner after reload',async()=>{
 for(const state of ['OK','FAIL']){
  const app=ui(response(200,{providers:{}}),200,state);
  await app.run('refreshImport()');
  for(const view of ['overview','subscriptions','configuration','diagnostics','settings']){
   app.run("document.documentElement.dataset={view:'"+view+"'};draw();");
   assert.equal(app.el('operation-banner').hidden,true,'historical result leaked into '+view);
  }
  assert.match(app.el('config-state').textContent,state==='OK'?/успешно/:/ошибке/);
 }
});

test('observed import completion stays in its view and can be dismissed without losing its result',async()=>{
 for(const state of ['OK','FAIL']){
  const app=ui(response(200,{providers:{}}),200,state);await app.run('refreshImport()');
  app.run("importData={state:'RUNNING'};importView='subscriptions';document.documentElement.dataset={view:'overview'};draw();");
  assert.equal(app.el('operation-banner').hidden,false);
  assert.equal(app.el('operation-dismiss').hidden,true);
  await app.run('refreshImport()');
  assert.equal(app.el('operation-banner').hidden,true);
  app.run("document.documentElement.dataset={view:'subscriptions'};draw();");
  assert.equal(app.el('operation-banner').hidden,false);
  assert.equal(app.el('operation-dismiss').hidden,false);
  await app.el('operation-dismiss').click();
  assert.equal(app.el('operation-banner').hidden,true);
  await app.run('refreshImport()');
  app.run("lang='en';draw();");
  assert.equal(app.el('operation-banner').hidden,true,'poll/language change resurrected dismissed result');
  assert.equal(app.run('importData.state'),state);
  app.run("importData={state:'RUNNING'};draw();");
  assert.equal(app.el('operation-banner').hidden,false,'new active operation must remain visible');
 }
});

const settingsFixture=async fixture=>{const app=ui(response(200,{providers:{}}),200,'UNKNOWN',fixture);await new Promise(setImmediate);return app;};
const settingsPosts=app=>app.requests.filter(r=>r.url==='/api/settings'&&r.options.method==='POST');
test('settings read uses actual existing port and read failure disables mutation',async()=>{
 const app=await settingsFixture({});assert.equal(app.el('settings-port').value,'18081');assert.equal(app.el('settings-save').disabled,false);
 const failed=await settingsFixture({settingsFail:true});assert.equal(failed.el('settings-save').disabled,true);assert.match(failed.el('settings-state').textContent,/SETTINGS_READ_FAILED/);
 await failed.run('saveSettings()');assert.equal(settingsPosts(failed).length,0);
});
test('settings mode controls fields and clears stale credentials',async()=>{
 const app=await settingsFixture({settings:{port:8081,auth_mode:'panel',login:'kas',password_set:true}});
 assert.equal(app.el('settings-current-row').hidden,false);assert.equal(app.el('settings-repeat-row').hidden,false);
 app.el('settings-password').value='cached password';app.el('settings-mode').value='entware';await app.run("el('settings-mode').handlers.change()");
 assert.equal(app.el('settings-password').value,'');assert.equal(app.el('settings-repeat-row').hidden,true);assert.equal(app.el('settings-password-row').hidden,false);assert.match(app.el('settings-login').textContent,/root/);
 app.el('settings-mode').value='none';await app.run('draw()');assert.equal(app.el('settings-password-row').hidden,true);
});
test('settings cancellation posts nothing and removes typed credentials',async()=>{
 const app=await settingsFixture({});app.el('settings-port').value='8081';app.el('settings-mode').value='panel';app.el('settings-password').value=app.el('settings-repeat').value='long-password-123';app.run('window.confirm=()=>false');
 await app.run('saveSettings()');assert.equal(settingsPosts(app).length,0);assert.equal(app.el('settings-password').value,'');assert.equal(app.stored.length,0);
});
test('settings keep existing panel password without accidental credential fields',async()=>{
 const app=await settingsFixture({settings:{port:18081,auth_mode:'panel',login:'kas',password_set:true}});
 app.el('settings-current').value='proof';await app.run('saveSettings()');
 assert.deepEqual(JSON.parse(settingsPosts(app)[0].options.body),{port:18081,auth_mode:'panel',current_password:'proof'});
 assert.equal(settingsPosts(app)[0].options.headers['X-KAS-Confirm'],'settings');assert.equal(app.el('settings-current').value,'');assert.equal(app.stored.length,0);
});
test('settings reject invalid new passwords and require current proof despite browser auth',async()=>{
 const app=await settingsFixture({settings:{port:18081,auth_mode:'panel',login:'kas',password_set:true}});
 app.el('settings-mode').value='none';await app.run('saveSettings()');assert.equal(settingsPosts(app).length,0);
 const fresh=await settingsFixture({});fresh.el('settings-mode').value='panel';fresh.el('settings-password').value=fresh.el('settings-repeat').value='too-short';await fresh.run('saveSettings()');assert.equal(settingsPosts(fresh).length,0);
 fresh.el('settings-password').value=fresh.el('settings-repeat').value='я'.repeat(65);await fresh.run('saveSettings()');assert.equal(settingsPosts(fresh).length,0);
});
test('settings root proof and disable/port warnings share one confirmation',async()=>{
 const app=await settingsFixture({});app.el('settings-mode').value='entware';app.el('settings-password').value='existing-root';await app.run('saveSettings()');
 assert.deepEqual(JSON.parse(settingsPosts(app)[0].options.body),{port:18081,auth_mode:'entware',password:'existing-root'});
 app.el('settings-mode').value='none';app.el('settings-port').value='8081';app.el('settings-current').value='existing-root';app.run("window.prompts=[];window.confirm=message=>{window.prompts.push(message);return true}");await app.run('saveSettings()');
 assert.equal(app.run('window.prompts.length'),1);assert.match(app.run('window.prompts[0]'),/отключён/);assert.match(app.run('window.prompts[0]'),/18081.*8081/);
 assert.equal(app.stored.length,0);
});
test('settings port conflict keeps old committed address and successful port offers safe link',async()=>{
 const conflict=await settingsFixture({settingsPost:response(409,{error_code:'PORT_IN_USE'})});conflict.el('settings-port').value='8081';await conflict.run('saveSettings()');assert.equal(conflict.run('settingsData.port'),18081);assert.equal(conflict.el('settings-address').hidden,true);assert.match(conflict.el('settings-state').textContent,/PORT_IN_USE/);
 const app=await settingsFixture({});app.el('settings-port').value='8081';await app.run('saveSettings()');assert.equal(app.el('settings-address').href,'http://router.test:8081/');assert.equal(app.el('settings-address').hidden,false);
 for(const value of ['http://evil.test:8081','http://router.test:8081/path','http://user@router.test:8081','javascript:alert(1)','http://router.test'])assert.equal(app.run('safeSettingsAddress('+JSON.stringify(value)+',8081)'), '');
});

test('new installation displays server default 8081 without client override',async()=>{
 const app=await settingsFixture({settings:{port:8081,auth_mode:'none',login:'',password_set:false}});assert.equal(app.el('settings-port').value,'8081');
 app.el('settings-password').value='stale-hidden-password';app.el('settings-current').value='stale-hidden-current';await app.run('saveSettings()');assert.deepEqual(JSON.parse(settingsPosts(app)[0].options.body),{port:8081,auth_mode:'none'});
});
test('existing Entware mode uses current proof only and never asks for a new root password',async()=>{
 const app=await settingsFixture({settings:{port:8081,auth_mode:'entware',login:'root',password_set:true}});
 assert.equal(app.el('settings-current-row').hidden,false);assert.equal(app.el('settings-password-row').hidden,true);assert.equal(app.el('settings-repeat-row').hidden,true);
 app.el('settings-current').value='existing-root';app.el('settings-password').value='stale-hidden';await app.run('saveSettings()');assert.deepEqual(JSON.parse(settingsPosts(app)[0].options.body),{port:8081,auth_mode:'entware',current_password:'existing-root'});
 assert.equal(app.el('settings-current').value,'');assert.equal(app.el('settings-password').value,'');
});

// A completed diagnostic is not a result of unrelated settings or config actions.
test('Doctor result stays in diagnostics; only a running Doctor has a global banner',async()=>{
 const app=ui(response(200,{providers:{}}));
 await new Promise(setImmediate);
 app.run("lastOperation='doctor';doctorData={exit_code:0,details:'Doctor report',timestamp:'test'};");
 for(const view of ['overview','subscriptions','configuration','diagnostics','settings']){
  app.run("document.documentElement.dataset={view:'"+view+"'};draw();");
  assert.equal(app.el('operation-banner').hidden,true,'completed Doctor leaked into '+view);
  assert.match(app.el('doctor-state').textContent,/Диагностика завершена/);
  assert.equal(app.el('output').textContent,'Doctor report');
 }
 app.run("document.documentElement.dataset={view:'settings'};busy=true;draw();");
 assert.equal(app.el('operation-banner').hidden,false);
 assert.match(app.el('operation-message').textContent,/Doctor/);
 app.run("document.documentElement.dataset={view:'diagnostics'};draw();");
 assert.equal(app.el('operation-banner').hidden,true);
});

test('component versions distinguish installed bundle from applied watchdog',async()=>{
 const fixture={components:{panel:{version:'0.1.0',source_sha:'a'.repeat(40)},core:{state:'present',version:'0.0.0~proof2-1',source_sha:'b'.repeat(40)},watchdog:{state:'bundle_changed',recorded_version:'0.0.0~proof1-1'}}};
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',fixture);
 await app.run('refreshComponents()');
 assert.match(app.el('panel-build').textContent,/KAS Web v0\.1\.0.*aaaaaaa/);
 assert.match(app.el('core-version').textContent,/v0\.0\.0-proof2/);
 assert.match(app.el('watchdog-version').textContent,/v0\.0\.0-proof1/);
 assert.doesNotMatch(app.el('watchdog-version').textContent,/совпадает/);
 fixture.components.watchdog={state:'stale',recorded_version:'0.0.0~proof1-1'};
 await app.run('refreshComponents()');
 assert.match(app.el('watchdog-version').textContent,/отличается/);
 fixture.components.panel.version='SECRET-TOKEN';
 await app.run('refreshComponents()');
 assert.doesNotMatch(app.el('panel-build').textContent,/SECRET|TOKEN/);
});

test('panel versions render the public v-form identically in RU and EN',async()=>{
 const fixture={components:{panel:{version:'0.1.0~beta.2-1',source_sha:'a'.repeat(40)},core:{state:'present',version:'0.0.0~proof2-1',source_sha:'b'.repeat(40)},watchdog:{state:'current',recorded_version:'0.0.0~proof2-1'}}};
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',fixture);
 await app.run('refreshComponents()');
 assert.match(app.el('panel-build').textContent,/KAS Web v0\.1\.0-beta\.2 · aaaaaaa/);
 assert.match(app.el('core-version').textContent,/v0\.0\.0-proof2 · bbbbbbb/);
 assert.match(app.el('watchdog-version').textContent,/v0\.0\.0-proof2 · файл совпадает/);
 assert.doesNotMatch(app.el('panel-build').textContent,/0\.1\.0~beta/);
 assert.doesNotMatch(app.el('panel-build').textContent,/vv/);
 for(const locale of ['en','ru']){
  app.run("lang='"+locale+"';draw();");
  assert.match(app.el('panel-build').textContent,/KAS Web v0\.1\.0-beta\.2 · aaaaaaa/);
 }
});

test('development and test-build panel versions stay honest',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{components:{panel:{version:'development',source_sha:''},core:{state:'absent'},watchdog:{state:'unrecorded'}}});
 await app.run('refreshComponents()');
 assert.match(app.el('panel-build').textContent,/KAS Web сборка для разработки/);
 assert.doesNotMatch(app.el('panel-build').textContent,/v[0-9]/);
 const lab=ui(response(200,{providers:{}}),200,'UNKNOWN',{components:{panel:{version:'0.0.1~test44.9c715283d525-1',source_sha:'a'.repeat(40)},core:{state:'absent'},watchdog:{state:'unrecorded'}}});
 await lab.run('refreshComponents()');
 assert.match(lab.el('panel-build').textContent,/KAS Web v0\.0\.1-test44\.9c715283d525 · aaaaaaa/);
});

test('overview shows process evidence and explicitly sourced versions',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 app.run(`statusData={timestamp:'test',mihomo_binary:true,magitrickle_binary:true,runtime:{mihomo:{state:'running',version:'1.19.33',version_source:'api'},magitrickle:{state:'stopped',version:'0.8.2-1',version_source:'package'}}};draw();`);
 assert.match(app.el('mihomo-file').textContent,/Процесс запущен.*1\.19\.33.*API/);
 assert.match(app.el('magitrickle-file').textContent,/Процесс не найден.*0\.8\.2-1.*пакет/);
 app.run(`statusData.runtime.mihomo={state:'unknown',version:'<SECRET>',version_source:'api'};draw();`);
 assert.match(app.el('mihomo-file').textContent,/не удалось проверить/);
 assert.doesNotMatch(app.el('mihomo-file').textContent,/SECRET/);
});
test('Doctor warnings are findings rather than command failure',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 app.run(`doctorData={exit_code:1,timestamp:'test',details:'full report',summary:{verdict:'WARN',ok:4,warn:2,fail:0,info:3}};draw();`);
 assert.match(app.el('doctor-state').textContent,/Предупреждения: 2/);
 assert.doesNotMatch(app.el('doctor-state').textContent,/Команда|не завершилась|ошибка:|код выхода/);
 app.run(`doctorData={exit_code:0,timestamp:'test',details:'incomplete report'};draw();`);
 assert.match(app.el('doctor-state').textContent,/Диагностика завершена.*не распознан/);
 app.run(`doctorData={exit_code:2,timestamp:'test',details:'report',summary:{verdict:'FAIL',ok:4,warn:1,fail:2,info:3}};draw();`);
 assert.match(app.el('doctor-state').textContent,/Ошибки: 2/);
});
test('script-installed watchdog shows its actual digest without a fictitious version',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{components:{panel:{version:'0.1.0',source_sha:'a'.repeat(40)},core:{state:'absent'},watchdog:{state:'unrecorded',installed_sha256:'b'.repeat(64)}}});
 await app.run('refreshComponents()');
 assert.match(app.el('watchdog-version').textContent,/Установлен.*bbbbbbbbbbbb/);
});

test('updates check is manual and confirmation cancellation never starts updater',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 assert.equal(app.requests.filter(r=>r.url==='/api/updates/check').length,0);
 assert.equal(app.el('update-mihomo').disabled,true);
 await app.run(`updateCheckData={state:'AVAILABLE',available_version:'1.20.0',current_version:'1.19.33',package_release:2,relation:'newer'};window.confirm=()=>false;draw();`);
 assert.equal(app.el('update-mihomo').disabled,false);
 await app.el('update-mihomo').click();
 assert.equal(app.requests.filter(r=>r.url==='/api/updates/mihomo').length,0);
});
test('older update candidate is disabled and running updater blocks other mutations',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 app.run(`updateCheckData={state:'AVAILABLE',available_version:'1.19.32',current_version:'1.19.33',package_release:2,relation:'older'};draw();`);
 assert.equal(app.el('update-mihomo').disabled,true);
 assert.match(app.el('updates-state').textContent,/старее/);
 app.run(`updateOperation={id:'op',state:'RUNNING'};draw();`);
 for(const id of ['apply','run','settings-save','update-check','update-mihomo'])assert.equal(app.el(id).disabled,true,id);
 assert.match(app.el('operation-message').textContent,/Mihomo/);
 app.run(`updateOperation={state:'OK',outcome:'UNCHANGED'};draw();`);
 assert.match(app.el('updates-state').textContent,/не измен/);
 app.run(`updateOperation={state:'FAIL',error_code:'UPDATE_FAILED'};draw();`);
 assert.match(app.el('updates-state').textContent,/Doctor/);
 assert.doesNotMatch(app.el('updates-state').textContent,/откачен|восстановлен/);
});

test('explicit check and repeated update clicks send only fixed empty-body commands',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 await app.el('update-check').click();
 const checks=app.requests.filter(r=>r.url==='/api/updates/check');assert.equal(checks.length,1);assert.equal(checks[0].options.body,'{}');
 await Promise.all([app.el('update-mihomo').click(),app.el('update-mihomo').click()]);
 const writes=app.requests.filter(r=>r.url==='/api/updates/mihomo');assert.equal(writes.length,1);assert.equal(writes[0].options.body,'{}');assert.equal(writes[0].options.headers['X-KAS-Confirm'],'update-mihomo');
 assert.equal(app.el('apply').disabled,true);assert.equal(app.el('access-save').disabled,true);
});

test('another tab replacing the update status does not leave a phantom running operation',async()=>{
 const fixture={updateOperation:{id:'new-op',state:'OK',outcome:'UNCHANGED'}};
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',fixture);await new Promise(setImmediate);
 app.run("updateOperation={id:'old-op',state:'RUNNING'};draw();");
 await app.run('refreshUpdateOperation()');
 assert.doesNotMatch(app.el('updates-state').textContent,/выполняется/);
 assert.match(app.el('updates-state').textContent,/STATUS_REPLACED/);
 assert.equal(app.el('apply').disabled,false);
 fixture.updateOperation={id:'other-running',state:'RUNNING'};
 app.run("updateOperation={id:'old-op',state:'RUNNING'};draw();");
 await app.run('refreshUpdateOperation()');
 assert.equal(app.el('apply').disabled,true);
 assert.equal(app.run('updateOperation.id'),'other-running');
});

test('lost update response reconciles the operation instead of leaving status unknown',async()=>{
 const fixture={updatePostError:true,updateOperation:{state:'UNKNOWN',error_code:'NO_OPERATION'}};
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',fixture);await new Promise(setImmediate);
 await app.el('update-check').click();
 fixture.updateOperation={id:'accepted-op',state:'RUNNING'};
 await app.el('update-mihomo').click();
 assert.ok(app.requests.filter(r=>r.url==='/api/updates/operation').length>=2);
 assert.equal(app.el('apply').disabled,true);
 assert.equal(app.run('updateOperation.id'),'accepted-op');
});

test('matching Mihomo version distinguishes opkg provenance and disables unnecessary update',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{updateCheck:{state:'AVAILABLE',current_version:'1.19.33',available_version:'1.19.33',package_release:2,installed_package_version:'1.19.32-1',relation:'same_runtime'}});await new Promise(setImmediate);
 await app.el('update-check').click();
 assert.equal(app.el('update-mihomo').disabled,true);
 assert.match(app.el('updates-state').textContent,/Работающий Mihomo: 1\.19\.33/);
 assert.match(app.el('updates-state').textContent,/opkg.*1\.19\.32-1/);
 assert.match(app.el('updates-state').textContent,/не подтверждён/);
 app.run("updateCheckData.relation='newer_package';draw();");assert.equal(app.el('update-mihomo').disabled,false);
});
test('MT check is manual, confirmation cancels and one named update blocks mutations',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 assert.equal(app.requests.filter(r=>r.url==='/api/updates/magitrickle/check').length,0);
 assert.equal(app.el('update-mt').disabled,true);await app.el('mt-check').click();
 assert.match(app.el('mt-state').textContent,/0\.8\.2-1.*0\.8\.2-2/);
 assert.equal(app.el('update-mt').disabled,false);
 app.run('window.confirm=()=>false');await app.el('update-mt').click();assert.equal(app.requests.filter(r=>r.url==='/api/updates/magitrickle').length,0);
 app.run('window.confirm=()=>true');await Promise.all([app.el('update-mt').click(),app.el('update-mt').click()]);
 const writes=app.requests.filter(r=>r.url==='/api/updates/magitrickle');assert.equal(writes.length,1);assert.equal(writes[0].options.body,'{}');assert.equal(writes[0].options.headers['X-KAS-Confirm'],'update-magitrickle');
 for(const id of ['apply','run','settings-save','update-mihomo','update-mt','mt-check'])assert.equal(app.el(id).disabled,true,id);
 assert.match(app.el('operation-message').textContent,/MagiTrickle/);
 app.run("updateOperation={component:'magitrickle',state:'FAIL',error_code:'MT_CONFIG_CHANGED'};draw();");
 assert.match(app.el('mt-state').textContent,/MT_CONFIG_CHANGED/);assert.doesNotMatch(app.el('mt-state').textContent,/восстановлен|откачен/);
});
test('MT no-upgrade result does not invent an available version or allow update',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{mtCheck:{state:'AVAILABLE',current_version:'0.8.2-1',relation:'no_upgrade'}});await new Promise(setImmediate);
 await app.el('mt-check').click();assert.equal(app.el('update-mt').disabled,true);assert.match(app.el('mt-state').textContent,/не предлагают/);
});
for(const component of ['mihomo','magitrickle'])test('lost '+component+' request never presents an old successful operation as the new result',async()=>{
 const fixture={updatePostError:component==='mihomo',mtPostError:component==='magitrickle',updateOperation:{id:'old-op',component,state:'OK',outcome:'CHANGED'}};
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',fixture);await new Promise(setImmediate);
 await app.el(component==='mihomo'?'update-check':'mt-check').click();
 await app.el(component==='mihomo'?'update-mihomo':'update-mt').click();
 const text=app.el(component==='mihomo'?'updates-state':'mt-state').textContent;
 assert.match(text,/не удалось/i);assert.doesNotMatch(text,/обновлён|завершено/i);
});

test('service links use this router, standard ports and no panel query or credentials',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{href:'http://192.168.107.1:8081/?private=value#overview'});await new Promise(setImmediate);
 assert.equal(app.el('open-mt').href,'http://192.168.107.1:8080/');
 assert.equal(app.el('open-mihomo').href,'http://192.168.107.1:9090/ui/');
 for(const id of ['open-mt','open-mihomo','open-generator']){assert.equal(app.el(id).target,'_blank');assert.equal(app.el(id).rel,'noopener noreferrer');}
 assert.equal(app.el('open-generator').href,'https://saymer-alt.github.io/link-generators/');
});
test('HTTPS proxy does not invent local service URLs',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{href:'https://panel.example/'});await new Promise(setImmediate);
 assert.equal(app.el('open-mt').hidden,true);assert.equal(app.el('open-mihomo').hidden,true);assert.match(app.el('service-links-note').textContent,/локальн/);
 assert.equal(app.el('open-generator').hidden,false);
});
for(const theme of ['auto','light','dark','invalid'])test('theme preference '+theme+' is local and validated',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{theme});await new Promise(setImmediate);
 assert.equal(app.run('document.documentElement["data-theme"]'),theme==='invalid'?'auto':theme);
 const before=app.requests.length;app.el('theme-mode').value='dark';app.el('theme-mode').handlers.change();
 assert.equal(app.run('document.documentElement["data-theme"]'),'dark');assert.equal(app.requests.length,before);
 assert.ok(app.stored.some(x=>x[0]==='kas_theme'&&x[1]==='dark'));
});
test('theme works when browser storage is unavailable',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{storageFail:true});await new Promise(setImmediate);
 app.el('theme-mode').value='dark';app.el('theme-mode').handlers.change();assert.equal(app.run('document.documentElement["data-theme"]'),'dark');
});
test('router panel link opens router root without the KAS port, credentials or query',async()=>{
 const app=ui(response(200,{providers:{}}),200,'UNKNOWN',{href:'http://user:password@192.168.107.1:8081/?private=value#overview'});await new Promise(setImmediate);
 assert.equal(app.el('local-badge').href,'http://192.168.107.1/');
 assert.equal(app.el('local-badge').target,'_blank');assert.equal(app.el('local-badge').rel,'noopener noreferrer');assert.equal(app.el('local-badge').hidden,false);
});
test('standalone disabled editor explains unavailability without a raw backend code',async()=>{
 const app=ui(response(200,{providers:{}}),404,'UNKNOWN',{inspectError:'EDITOR_DISABLED'});await new Promise(setImmediate);
 await app.el('filter-load').click();assert.doesNotMatch(app.el('filter-state').textContent,/EDITOR_DISABLED/);assert.match(app.el('filter-state').textContent,/режим.*запуска/);
 assert.equal(app.el('filter-preview').disabled,true);
});


test('Doctor cards translate without re-running probes and preserve original copy output',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 const report=fs.readFileSync(path.join(__dirname,'fixtures/doctor-kn1010.txt'),'utf8');
 const data={details:report,exit_code:0,summary:{verdict:'OK',ok:37,warn:0,fail:0,info:65}};
 app.run('doctorData='+JSON.stringify(data)+';draw();');
 const text=node=>[node.textContent,...(node.children||[]).map(text)].join(' ');
 assert.equal(app.el('doctor-summary').hidden,false);
 assert.match(text(app.el('doctor-summary')),/Внешний накопитель.*14115 из 14190 МБ/);
 assert.match(text(app.el('doctor-summary')),/Перезапуски в истории watchdog/);
 app.run("lang='en';draw();");
 assert.match(text(app.el('doctor-summary')),/External storage.*14115 of 14190 MB/);
 assert.equal(app.el('output').textContent,report);
 assert.equal(app.requests.filter(r=>r.url==='/api/doctor').length,0);
 assert.equal(app.stored.length,0,'report must not be persisted');
 app.run("doctorData={details:'incomplete',exit_code:0};draw();");
 assert.match(text(app.el('doctor-summary')),/Overview unavailable/);
 assert.doesNotMatch(text(app.el('doctor-summary')),/External storage|14115/);
});


test('operation navigation is hidden in its own view and honestly labelled elsewhere',async()=>{
 const app=ui(response(200,{providers:{}}));await new Promise(setImmediate);
 app.run("importData={state:'RUNNING'};importView='subscriptions';document.documentElement.dataset={view:'overview'};draw();");
 assert.equal(app.el('operation-open').hidden,false);
 assert.equal(app.el('operation-open').textContent,'Перейти к операции');
 app.run("document.documentElement.dataset={view:'subscriptions'};draw();");
 assert.equal(app.el('operation-open').hidden,true);
 app.run("importData={state:'OK',exit_code:0};draw();");
 assert.equal(app.el('operation-open').hidden,true);
 assert.equal(app.el('operation-dismiss').hidden,false);
 app.run("importData=null;busy=true;document.documentElement.dataset={view:'overview'};lang='en';draw();");
 assert.equal(app.el('operation-open').hidden,false);
 assert.equal(app.el('operation-open').textContent,'Go to operation');
});
