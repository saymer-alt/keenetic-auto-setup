// Exercise the real UI on an insecure origin, as on a router's HTTP LAN address.
const {chromium}=require('playwright');
const path=require('node:path');
const assert=require('node:assert/strict');
const assets=path.resolve(__dirname,'../web');
const report='Doctor fixture\n[OK] Проверка завершена\nWARN: 0\nFAIL: 0\n';
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.KAS_TEST_CHROMIUM||undefined,args:['--no-sandbox']});
 try{
  const page=await browser.newPage({locale:'ru-RU'});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('http://kas.test/**',route=>{
   const pathname=new URL(route.request().url()).pathname;
   if(!pathname.startsWith('/api/'))return route.fulfill({path:path.join(assets,pathname==='/'?'index.html':pathname.slice(1))});
   const data=pathname==='/api/settings'?{port:8081,auth_mode:'none',login:'',password_set:false}:
    pathname==='/api/access'?{home_only:false}:
    pathname==='/api/doctor'?{exit_code:0,timestamp:'2026-10-28T16:16:26Z',details:report}:
    pathname==='/api/config/operation'?{state:'UNKNOWN',error_code:'NO_OPERATION'}:{};
   return route.fulfill({json:data});
  });
  await page.goto('http://kas.test/');
  assert.equal(await page.evaluate(()=>isSecureContext),false);
  assert.equal(await page.evaluate(()=>typeof navigator.clipboard),'undefined');
  await page.locator('#nav-diagnostics').click();await page.locator('#run').click();
  await page.waitForFunction(()=>!document.getElementById('copy').disabled);
  // The paste destination is test-only; the copy command and OS clipboard are real.
  await page.evaluate(()=>{const input=document.createElement('textarea');input.id='paste-test';document.body.append(input);});
  await page.locator('#copy').click();
  await page.locator('#paste-test').focus();await page.keyboard.press('Control+V');
  assert.equal(await page.locator('#paste-test').inputValue(),report,'HTTP button must copy the complete report');
  assert.match(await page.locator('#copy-state').innerText(),/скопирован/i);
  // A denied modern API must also fall back to the real HTTP copy command.
  await page.evaluate(()=>{Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async()=>{throw new Error('Denied');}}});});
  await page.locator('#paste-test').fill('');await page.locator('#copy').click();
  await page.locator('#paste-test').focus();await page.keyboard.press('Control+V');
  assert.equal(await page.locator('#paste-test').inputValue(),report);
  // Simulate a browser denying both copying mechanisms; offer manual selection.
  await page.evaluate(()=>{document.execCommand=()=>false;});
  await page.locator('#copy').click();
  assert.match(await page.locator('#copy-state').innerText(),/Ctrl\+C/);
  assert.equal(await page.evaluate(()=>getSelection().toString()),report.trimEnd());
  assert.equal(await page.locator('#output').isVisible(),true);
  await page.locator('#en').click();assert.match(await page.locator('#copy-state').innerText(),/Ctrl\+C/);
  assert.deepEqual(errors,[]);
  console.log('PASS: HTTP Doctor copy/paste preserves full report; denied copy selects visible report and explains manual copy.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
