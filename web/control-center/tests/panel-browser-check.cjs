// Optional real-browser check: requires development-only Playwright.
// Set KAS_TEST_CHROMIUM to an existing Chrome executable, or install Playwright Chromium.
const {chromium}=require('playwright');
const fs=require('node:fs');const path=require('node:path');const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../..');
const previews=process.env.KAS_PREVIEW_DIR||path.join(root,'web/control-center/design-preview');fs.mkdirSync(previews,{recursive:true});
let browser;
(async()=>{
 browser=await chromium.launch({headless:true,executablePath:process.env.KAS_TEST_CHROMIUM||undefined,args:['--no-sandbox']});
 const page=await browser.newPage({viewport:{width:1440,height:1000},locale:'ru-RU'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 let panelOperation=null,panelTarget=false,panelLoseResponse=false;let updateOperation=null;let filtered=false,operation=null,acceptDialog=false,settingsReadFail=false,portConflict=false;let settings={port:18081,auth_mode:'none',login:'',password_set:false};const requests=[];
 page.on('dialog',d=>acceptDialog?d.accept():d.dismiss());
 const names=['Sweden Reality 8443','Sweden XHTTP 2053','Sweden gRPC 2096','Sweden Hy2 2083','Estonia Reality 8443','Estonia XHTTP 2053','Estonia gRPC 2096','Estonia Trojan 9443','Estonia Hy2 2083','Sweden2 Reality 8443','Sweden2 XHTTP 2053','Sweden2 gRPC 2096','Sweden2 Hy2 2083','Moscow Hy2 2083'];
 await page.route('http://kas.test/**',async route=>{
  const req=route.request(),url=new URL(req.url());
  if(!url.pathname.startsWith('/api/')){
   const file=path.join(root,'web/control-center/web',url.pathname==='/'?'index.html':url.pathname.slice(1));
   return route.fulfill({path:file,contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'text/html'});
  }
  requests.push({path:url.pathname,body:req.postDataJSON()});let data={},status=200;
  if(url.pathname==='/api/updates/panel/check')data={state:'OK',channel:'experimental',installed_version:'0.1.0',runtime_version:'0.1.0',available_version:'0.1.1',relation:'newer'};
  if(url.pathname==='/api/updates/panel/operation')data=panelOperation||{state:'UNKNOWN',error_code:'NO_OPERATION'};
  if(url.pathname==='/api/updates/panel/apply'){panelOperation={ID:'c'.repeat(24),State:'RUNNING',Phase:'install',Version:'0.1.1',SourceSHA:'d'.repeat(40),Gate:true};if(panelLoseResponse)return route.abort();data={id:panelOperation.ID,state:'RUNNING'};status=202;}
  if(url.pathname==='/api/updates/check')data={state:'AVAILABLE',current_version:'1.19.33',available_version:'1.20.0',package_release:2,relation:'newer'};
  if(url.pathname==='/api/updates/mihomo'){updateOperation={id:'update-fixture',state:'OK',outcome:'UNCHANGED',exit_code:0};data={id:'update-fixture',state:'RUNNING'};status=202;}
  if(url.pathname==='/api/updates/magitrickle/check')data={state:'AVAILABLE',current_version:'0.8.2-1',available_version:'0.8.2-2',relation:'newer'};
  if(url.pathname==='/api/updates/magitrickle'){updateOperation={id:'mt-fixture',component:'magitrickle',state:'OK',outcome:'CHANGED'};data={...updateOperation,state:'RUNNING'};status=202;}
  if(url.pathname==='/api/updates/operation')data=updateOperation||{state:'UNKNOWN',error_code:'NO_OPERATION'};
  if(url.pathname==='/api/components')data={panel:{version:panelTarget?'0.1.1':'0.1.0',source_sha:(panelTarget?'d':'a').repeat(40)},core:{state:'present',version:'0.0.0~proof2-1',source_sha:'b'.repeat(40)},watchdog:{state:'current',recorded_version:'0.0.0~proof2-1'}};
  if(url.pathname==='/api/status')data={timestamp:'2026-10-28T14:00:00Z',mihomo_binary:true,magitrickle_binary:true,runtime:{mihomo:{state:'running',version:'1.19.33',version_source:'api'},magitrickle:{state:'running',version:'0.8.2-1',version_source:'package'}}};
  if(url.pathname==='/api/doctor')data={timestamp:'2026-10-29T07:00:00Z',exit_code:0,details:fs.readFileSync(path.join(root,'web/control-center/tests/fixtures/doctor-kn1010.txt'),'utf8'),summary:{verdict:'OK',ok:37,warn:0,fail:0,info:65}};
  if(url.pathname==='/api/access')data={home_only:false};
  if(url.pathname==='/api/settings'){
   data=settings;
   if(settingsReadFail){status=503;data={error_code:'SETTINGS_READ_FAILED'};}
   else if(req.method()==='POST'){
    if(portConflict){status=409;data={error_code:'PORT_IN_USE'};}
    else {const body=req.postDataJSON();settings={port:body.port,auth_mode:body.auth_mode,login:({none:'',panel:'kas',entware:'root'})[body.auth_mode],password_set:body.auth_mode!=='none'};data={...settings,url:'http://kas.test:'+settings.port};}
   }
  }
  if(url.pathname==='/api/filter/providers')data={source_sha:'a'.repeat(64),providers:[{name:'gist.githubusercontent.com',http:true,has_filter:filtered,existing_filter:filtered?'^(?:Estonia Hy2 2083)$':''}]};
  if(url.pathname==='/api/providers/names')data={providers:{'gist.githubusercontent.com':{proxies:names.filter(n=>!filtered||n!=='Estonia Hy2 2083').map(name=>({name}))}}};
  if(url.pathname==='/api/filter/preview')data={existing_filter:filtered?'Old':'',proposed_filter:req.postDataJSON().clear?'':'New'};
  if(url.pathname==='/api/filter/apply'){filtered=!req.postDataJSON().clear;operation={id:'op',state:'OK',exit_code:0};data={...operation,state:'RUNNING'};status=202;}
  if(url.pathname==='/api/config/operation')data=operation||{state:'UNKNOWN',error_code:'NO_OPERATION'};
  return route.fulfill({status,json:data});
 });
 await page.goto('http://kas.test/');await page.locator('#mihomo-file').filter({hasText:'Процесс запущен'}).waitFor();
 await page.waitForFunction(()=>document.getElementById('panel-build').textContent.includes('0.1.0'));
 assert.match(await page.locator('#core-version').innerText(),/proof2-1/);assert.match(await page.locator('#watchdog-version').innerText(),/совпадает/);
 assert.equal(await page.locator('#project-link').getAttribute('href'),'https://github.com/saymer-alt/keenetic-auto-setup');
 assert.equal(await page.locator('#open-mt').getAttribute('href'),'http://kas.test:8080/');
 assert.equal(await page.locator('#open-mihomo').getAttribute('href'),'http://kas.test:9090/ui/');
 assert.equal(await page.locator('#open-generator').getAttribute('href'),'https://saymer-alt.github.io/link-generators/');
 assert.equal(await page.locator('#local-badge').getAttribute('href'),'http://kas.test/');
 for(const id of ['local-badge','open-mt','open-mihomo','open-generator']){assert.equal(await page.locator('#'+id).getAttribute('target'),'_blank');assert.equal(await page.locator('#'+id).getAttribute('rel'),'noopener noreferrer');}
 await page.emulateMedia({colorScheme:'light'});await page.locator('#nav-settings').click();
 await page.locator('#theme-mode').selectOption('dark');
 const background=()=>page.evaluate(()=>getComputedStyle(document.body).backgroundColor);
 assert.equal(await background(),'rgb(17, 23, 34)');
 await page.reload();await page.locator('#nav-settings').click();await page.locator('#theme-mode').waitFor();assert.equal(await page.locator('#theme-mode').inputValue(),'dark');assert.equal(await background(),'rgb(17, 23, 34)');
 await page.emulateMedia({colorScheme:'dark'});await page.locator('#theme-mode').selectOption('light');assert.equal(await background(),'rgb(243, 245, 249)');
 await page.locator('#theme-mode').selectOption('auto');assert.equal(await background(),'rgb(17, 23, 34)');
 await page.emulateMedia({colorScheme:'light'});assert.equal(await background(),'rgb(243, 245, 249)');
 await page.locator('#nav-overview').click();
 assert.match(await page.locator('#mihomo-file').innerText(),/1\.19\.33.*API/);assert.match(await page.locator('#magitrickle-file').innerText(),/0\.8\.2-1.*пакет/);
 assert.equal(requests.filter(r=>r.path==='/api/updates/check').length,0);
 await page.locator('#update-check').click();await page.waitForFunction(()=>!document.getElementById('update-mihomo').disabled);
 assert.match(await page.locator('#updates-state').innerText(),/1\.20\.0-2/);
 acceptDialog=false;await page.locator('#update-mihomo').click();assert.equal(requests.filter(r=>r.path==='/api/updates/mihomo').length,0);
 acceptDialog=true;await page.locator('#update-mihomo').click();assert.equal(await page.locator('#apply').isDisabled(),true);
 await page.waitForFunction(()=>document.getElementById('updates-state').textContent.includes('не изменился'));
 assert.equal(requests.filter(r=>r.path==='/api/updates/mihomo').length,1);
 assert.equal(requests.filter(r=>r.path==='/api/updates/magitrickle/check').length,0);
 await page.locator('#mt-check').click();await page.waitForFunction(()=>!document.getElementById('update-mt').disabled);
 assert.match(await page.locator('#mt-state').innerText(),/0\.8\.2-1.*0\.8\.2-2/);
 acceptDialog=false;await page.locator('#update-mt').click();assert.equal(requests.filter(r=>r.path==='/api/updates/magitrickle').length,0);
 acceptDialog=true;await page.locator('#update-mt').click();assert.equal(await page.locator('#run').isDisabled(),true);
 await page.waitForFunction(()=>document.getElementById('mt-state').textContent.includes('процесс запущен'));
 assert.equal(requests.filter(r=>r.path==='/api/updates/magitrickle').length,1);
 await page.screenshot({path:path.join(previews,'overview-desktop.png'),fullPage:true});
 await page.locator('#nav-diagnostics').click();await page.locator('#run').click();await page.waitForFunction(()=>document.getElementById('doctor-state').textContent.includes('Ошибок и предупреждений не обнаружено'));
 assert.doesNotMatch(await page.locator('#doctor-state').innerText(),/код выхода|не завершилась/);
 assert.match(await page.locator('#doctor-summary').innerText(),/Внешний накопитель[\s\S]*14115 из 14190 МБ/);
 const doctorCalls=requests.filter(r=>r.path==='/api/doctor').length;
 await page.locator('#en').click();assert.match(await page.locator('#doctor-summary').innerText(),/External storage[\s\S]*14115 of 14190 MB/);
 assert.equal(requests.filter(r=>r.path==='/api/doctor').length,doctorCalls);await page.locator('#ru').click();
 await page.screenshot({path:path.join(previews,'diagnostics-desktop.png'),fullPage:true});
 await page.locator('#nav-subscriptions').click();await page.locator('#filter-load').click();await page.locator('#filter-node-list label').first().waitFor();
 assert.equal(await page.locator('.view:visible').count(),1);
 await page.locator('#filter-search').fill('Estonia');assert.equal(await page.locator('#filter-node-list label:visible').count(),5);
 await page.locator('#filter-node-list label').filter({hasText:'Estonia Hy2 2083'}).locator('input').check();
 await page.locator('#filter-search').fill('Sweden');assert.match(await page.locator('#filter-summary').innerText(),/Выбрано: 1/);
 await page.locator('#nav-configuration').click();await page.locator('#yaml-paste').fill('mixed-port: 7890\n# keep me');
 await page.locator('#nav-subscriptions').click();assert.equal(await page.locator('#filter-node-list input:checked').count(),1);
 await page.locator('#en').click();assert.equal(await page.locator('#page-title').innerText(),'Subscriptions');assert.match(await page.locator('#filter-summary').innerText(),/Selected: 1/);
 await page.locator('#ru').click();await page.locator('#filter-search').fill('');
 await page.screenshot({path:path.join(previews,'subscriptions-desktop.png'),fullPage:true});
 acceptDialog=false;await page.locator('#filter-preview').click();await page.waitForFunction(()=>document.getElementById('filter-state').textContent.includes('отменено'));assert.equal(requests.filter(r=>r.path==='/api/filter/apply').length,0);
 acceptDialog=true;await page.locator('#filter-preview').click();await page.waitForFunction(()=>document.getElementById('filter-clear').disabled===false);
 assert.equal(requests.filter(r=>r.path==='/api/filter/apply').length,1);
 await page.waitForFunction(()=>document.getElementById('filter-state').textContent.includes('Фильтр обновлён'));
 assert.equal(await page.locator('#operation-banner').isVisible(),true);
 assert.equal(await page.locator('#operation-open').isVisible(),false,'operation navigation must not target the already open view');
 await page.locator('#nav-overview').click();assert.equal(await page.locator('#operation-banner').isVisible(),false);
 await page.locator('#nav-subscriptions').click();assert.match(await page.locator('#operation-message').innerText(),/успешно/);
 await page.locator('#operation-dismiss').click();assert.equal(await page.locator('#operation-banner').isVisible(),false);
 acceptDialog=true;await page.locator('#filter-clear').click();await page.waitForFunction(()=>document.querySelectorAll('#filter-node-list input').length===14&&document.getElementById('filter-clear').disabled);
 assert.equal(requests.filter(r=>r.path==='/api/filter/apply').length,2);
 const applied=requests.filter(r=>r.path==='/api/filter/apply');assert.deepEqual(applied[0].body.names,['Estonia Hy2 2083']);assert.equal(applied[1].body.clear,true);
 await page.locator('#nav-configuration').click();assert.equal(await page.locator('#yaml-paste').inputValue(),'mixed-port: 7890\n# keep me');
 await page.locator('#nav-settings').click();await page.waitForFunction(()=>!document.getElementById('settings-save').disabled);
 assert.equal(await page.locator('#settings-port').inputValue(),'18081');
 await page.screenshot({path:path.join(previews,'settings-desktop.png'),fullPage:true});
 assert.equal(await page.locator('#settings-password').isVisible(),false);
 await page.locator('#settings-mode').selectOption('panel');assert.equal(await page.locator('#settings-repeat').isVisible(),true);
 await page.locator('#settings-password').fill('long-panel-password');await page.locator('#settings-repeat').fill('long-panel-password');
 acceptDialog=false;await page.locator('#settings-save').click();assert.equal(requests.filter(r=>r.path==='/api/settings'&&r.body).length,0);assert.equal(await page.locator('#settings-password').inputValue(),'');
 await page.locator('#settings-password').fill('long-panel-password');await page.locator('#settings-repeat').fill('long-panel-password');acceptDialog=true;await page.locator('#settings-save').click();await page.waitForFunction(()=>document.getElementById('settings-state').textContent.includes('сохранены'));
 assert.equal(await page.locator('#settings-current').isVisible(),true);assert.equal(await page.locator('#settings-password').inputValue(),'');
 assert.equal(requests.filter(r=>r.path==='/api/settings'&&r.body).length,1);
 await page.locator('#settings-current').fill('long-panel-password');await page.locator('#settings-port').fill('8081');portConflict=true;await page.locator('#settings-save').click();await page.waitForFunction(()=>document.getElementById('settings-state').textContent.includes('PORT_IN_USE'));
 assert.equal(page.url(),'http://kas.test/');assert.equal(await page.locator('#settings-address').isVisible(),false);
 portConflict=false;await page.locator('#settings-current').fill('long-panel-password');await page.locator('#settings-save').click();await page.locator('#settings-address').waitFor();assert.equal(await page.locator('#settings-address').getAttribute('href'),'http://kas.test:8081/');
 assert.equal(await page.locator('#settings-current').inputValue(),'');
 const portBody=requests.filter(r=>r.path==='/api/settings'&&r.body).at(-1).body;assert.deepEqual(portBody,{port:8081,auth_mode:'panel',current_password:'long-panel-password'});
 await page.locator('#settings-mode').selectOption('entware');assert.equal(await page.locator('#settings-repeat').isVisible(),false);assert.match(await page.locator('#settings-login').innerText(),/root/);
 await page.setViewportSize({width:390,height:844});await page.screenshot({path:path.join(previews,'settings-mobile.png'),fullPage:true});await page.setViewportSize({width:1440,height:1000});
 await page.locator('#settings-mode').selectOption('none');assert.equal(await page.locator('#settings-password').isVisible(),false);
 settingsReadFail=true;await page.locator('#settings-reload').click();await page.waitForFunction(()=>document.getElementById('settings-state').textContent.includes('SETTINGS_READ_FAILED'));assert.equal(await page.locator('#settings-save').isDisabled(),true);
 assert.deepEqual(await page.evaluate(()=>Object.keys(localStorage).filter(key=>!['kas_lang','kas_theme'].includes(key))),[]);
 settingsReadFail=false;await page.locator('#settings-reload').click();await page.waitForFunction(()=>!document.getElementById('settings-save').disabled);
 await page.locator('#nav-overview').focus();await page.keyboard.press('ArrowRight');assert.equal(await page.locator('#nav-subscriptions').getAttribute('aria-current'),'page');
 for(const width of [360,390,768,1440]){
  await page.setViewportSize({width,height:900});
  for(const view of ['overview','subscriptions','configuration','diagnostics','settings']){
   await page.locator('#nav-'+view).click();
   assert.ok(await page.locator('#local-badge').isVisible(),`router link hidden at ${width}/${view}`);
   assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`overflow at ${width}/${view}`);
  }
 }
 await page.locator('#nav-overview').click();
 assert.equal(requests.filter(r=>r.path==='/api/updates/panel/check').length,0,'panel check must be explicit');
 await page.locator('#panel-update-check').click();await page.waitForFunction(()=>!document.getElementById('panel-update-apply').disabled);
 acceptDialog=false;await page.locator('#panel-update-apply').click();assert.equal(requests.filter(r=>r.path==='/api/updates/panel/apply').length,0);
 acceptDialog=true;panelLoseResponse=true;await page.locator('#panel-update-apply').click();
 await page.waitForFunction(()=>document.getElementById('panel-update-state').textContent.includes('install'));
 assert.equal(await page.locator('#update-mihomo').isDisabled(),true);
 await page.reload();await page.waitForFunction(()=>document.getElementById('panel-update-state').textContent.includes('install'));
 panelOperation={...panelOperation,State:'OK',Phase:'complete',Gate:false};
 await page.waitForFunction(()=>document.getElementById('panel-update-state').textContent.includes('ещё не подтверждена'));
 panelTarget=true;await page.waitForFunction(()=>document.getElementById('panel-update-state').textContent.includes('Новая запущенная версия подтверждена'));
 await page.locator('#en').click();assert.match(await page.locator('#panel-update-state').innerText(),/New running version verified/);await page.locator('#ru').click();
 await page.setViewportSize({width:390,height:844});await page.locator('#nav-subscriptions').click();
 await page.screenshot({path:path.join(previews,'subscriptions-mobile.png'),fullPage:true});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:path.join(previews,'subscriptions-dark-mobile.png'),fullPage:true});
 await page.reload();await page.locator('#mihomo-file').filter({hasText:'Процесс запущен'}).waitFor();
 assert.equal(await page.locator('#operation-banner').isVisible(),false,'historical result reappeared on reload');
 assert.deepEqual(errors,[]);console.log('PASS: real Chromium navigation, RU/EN, search, preserved selections/YAML, cancel/apply/clear, settings modes/cancel/current proof/port conflict/address/read failure/no credential storage, keyboard, 4 screen widths, dark mode; no JS errors.');
 await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1}).finally(async()=>{await browser?.close();});
