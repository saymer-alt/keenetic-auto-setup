// Optional real-browser check: requires development-only Playwright.
// Set KAS_TEST_CHROMIUM to an existing Chrome executable, or install Playwright Chromium.
const {chromium}=require('playwright');
const fs=require('node:fs');const path=require('node:path');const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../..');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.KAS_TEST_CHROMIUM||undefined,args:['--no-sandbox']});
 const page=await browser.newPage({viewport:{width:1440,height:1000},locale:'ru-RU'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 let filtered=false,operation=null,acceptDialog=false;const requests=[];
 page.on('dialog',d=>acceptDialog?d.accept():d.dismiss());
 const names=['Sweden Reality 8443','Sweden XHTTP 2053','Sweden gRPC 2096','Sweden Hy2 2083','Estonia Reality 8443','Estonia XHTTP 2053','Estonia gRPC 2096','Estonia Trojan 9443','Estonia Hy2 2083','Sweden2 Reality 8443','Sweden2 XHTTP 2053','Sweden2 gRPC 2096','Sweden2 Hy2 2083','Moscow Hy2 2083'];
 await page.route('http://kas.test/**',async route=>{
  const req=route.request(),url=new URL(req.url());
  if(!url.pathname.startsWith('/api/')){
   const file=path.join(root,'web/control-center/web',url.pathname==='/'?'index.html':url.pathname.slice(1));
   return route.fulfill({path:file,contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'text/html'});
  }
  requests.push({path:url.pathname,body:req.postDataJSON()});let data={},status=200;
  if(url.pathname==='/api/status')data={timestamp:'2026-10-28T14:00:00Z',mihomo_binary:true,magitrickle_binary:true};
  if(url.pathname==='/api/access')data={home_only:false};
  if(url.pathname==='/api/filter/providers')data={source_sha:'a'.repeat(64),providers:[{name:'gist.githubusercontent.com',http:true,has_filter:filtered,existing_filter:filtered?'^(?:Estonia Hy2 2083)$':''}]};
  if(url.pathname==='/api/providers/names')data={providers:{'gist.githubusercontent.com':{proxies:names.filter(n=>!filtered||n!=='Estonia Hy2 2083').map(name=>({name}))}}};
  if(url.pathname==='/api/filter/preview')data={existing_filter:filtered?'Old':'',proposed_filter:req.postDataJSON().clear?'':'New'};
  if(url.pathname==='/api/filter/apply'){filtered=!req.postDataJSON().clear;operation={id:'op',state:'OK',exit_code:0};data={...operation,state:'RUNNING'};status=202;}
  if(url.pathname==='/api/config/operation')data=operation||{state:'UNKNOWN',error_code:'NO_OPERATION'};
  return route.fulfill({status,json:data});
 });
 await page.goto('http://kas.test/');await page.locator('#mihomo-file').filter({hasText:'найден'}).waitFor();
 await page.screenshot({path:path.join(root,'web/control-center/design-preview/overview-desktop.png'),fullPage:true});
 await page.locator('#nav-subscriptions').click();await page.locator('#filter-load').click();await page.locator('#filter-node-list label').first().waitFor();
 assert.equal(await page.locator('.view:visible').count(),1);
 await page.locator('#filter-search').fill('Estonia');assert.equal(await page.locator('#filter-node-list label:visible').count(),5);
 await page.locator('#filter-node-list label').filter({hasText:'Estonia Hy2 2083'}).locator('input').check();
 await page.locator('#filter-search').fill('Sweden');assert.match(await page.locator('#filter-summary').innerText(),/Выбрано: 1/);
 await page.locator('#nav-configuration').click();await page.locator('#yaml-paste').fill('mixed-port: 7890\n# keep me');
 await page.locator('#nav-subscriptions').click();assert.equal(await page.locator('#filter-node-list input:checked').count(),1);
 await page.locator('#en').click();assert.equal(await page.locator('#page-title').innerText(),'Subscriptions');assert.match(await page.locator('#filter-summary').innerText(),/Selected: 1/);
 await page.locator('#ru').click();await page.locator('#filter-search').fill('');
 await page.screenshot({path:path.join(root,'web/control-center/design-preview/subscriptions-desktop.png'),fullPage:true});
 acceptDialog=false;await page.locator('#filter-preview').click();await page.waitForFunction(()=>document.getElementById('filter-state').textContent.includes('отменено'));assert.equal(requests.filter(r=>r.path==='/api/filter/apply').length,0);
 acceptDialog=true;await page.locator('#filter-preview').click();await page.waitForFunction(()=>document.getElementById('filter-clear').disabled===false);
 assert.equal(requests.filter(r=>r.path==='/api/filter/apply').length,1);
 await page.locator('#nav-overview').click();await page.locator('#operation-banner').waitFor();assert.match(await page.locator('#operation-message').innerText(),/успешно/);await page.locator('#operation-open').click();assert.equal(await page.locator('#page-title').innerText(),'Подписки');
 acceptDialog=true;await page.locator('#filter-clear').click();await page.waitForFunction(()=>document.querySelectorAll('#filter-node-list input').length===14&&document.getElementById('filter-clear').disabled);
 assert.equal(requests.filter(r=>r.path==='/api/filter/apply').length,2);
 const applied=requests.filter(r=>r.path==='/api/filter/apply');assert.deepEqual(applied[0].body.names,['Estonia Hy2 2083']);assert.equal(applied[1].body.clear,true);
 await page.locator('#nav-configuration').click();assert.equal(await page.locator('#yaml-paste').inputValue(),'mixed-port: 7890\n# keep me');
 await page.locator('#nav-overview').focus();await page.keyboard.press('ArrowRight');assert.equal(await page.locator('#nav-subscriptions').getAttribute('aria-current'),'page');
 for(const width of [360,390,768,1440]){
  await page.setViewportSize({width,height:900});
  for(const view of ['overview','subscriptions','configuration','diagnostics','settings']){
   await page.locator('#nav-'+view).click();
   assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`overflow at ${width}/${view}`);
  }
 }
 await page.setViewportSize({width:390,height:844});await page.locator('#nav-subscriptions').click();
 await page.screenshot({path:path.join(root,'web/control-center/design-preview/subscriptions-mobile.png'),fullPage:true});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:path.join(root,'web/control-center/design-preview/subscriptions-dark-mobile.png'),fullPage:true});
 assert.deepEqual(errors,[]);console.log('PASS: real Chromium navigation, RU/EN, search, preserved selections/YAML, cancel/apply/clear, keyboard, 4 screen widths, dark mode; no JS errors.');
 await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1});
