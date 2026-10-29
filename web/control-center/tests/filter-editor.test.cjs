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
  document:{documentElement:{},getElementById:el,createElement:()=>new Element(),createTextNode:text=>({textContent:text})},
  localStorage:{getItem:()=>null,setItem:(...args)=>stored.push(args)},navigator:{language:'ru'},window:{confirm:()=>true,location:{href:'http://router.test:18081/'}},URL,
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

test('completed and failed imports remain visible in the global operation banner',async()=>{
 for(const state of ['OK','FAIL']){
  const app=ui(response(200,{providers:{}}),200,state);
  await app.run('refreshImport()');
  assert.equal(app.el('operation-banner').hidden,false);
  assert.match(app.el('operation-message').textContent,state==='OK'?/успешно/:/ошибке/);
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
 assert.match(app.el('panel-build').textContent,/0\.1\.0.*aaaaaaa/);
 assert.match(app.el('core-version').textContent,/proof2-1/);
 assert.match(app.el('watchdog-version').textContent,/proof1-1/);
 assert.doesNotMatch(app.el('watchdog-version').textContent,/совпадает/);
 fixture.components.watchdog={state:'stale',recorded_version:'0.0.0~proof1-1'};
 await app.run('refreshComponents()');
 assert.match(app.el('watchdog-version').textContent,/отличается/);
 fixture.components.panel.version='SECRET-TOKEN';
 await app.run('refreshComponents()');
 assert.doesNotMatch(app.el('panel-build').textContent,/SECRET|TOKEN/);
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
