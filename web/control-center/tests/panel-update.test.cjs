const {test}=require('node:test');const assert=require('node:assert/strict');
const api=require('../web/panel-update.js');
test('unpublished stable channel is a normal status and cannot be installed',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async(path,opts)=>({ok:true,json:async()=>{
  if(path==='/api/updates/panel/channel')return {channel:'stable',allowed:['experimental','stable']};
  if(path==='/api/updates/panel/check')return {state:'UNPUBLISHED',channel:'stable',relation:'not_newer',installed_version:'0.1.0~beta.2-1',runtime_version:'0.1.0~beta.2-1'};
  return {ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'};
 }});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);
  await nodes['panel-update-check'].listeners.click();
  const message=nodes['panel-update-state'].textContent;
  assert.match(message,/Стабильная версия KAS WEB пока не выпущена/);
  assert.match(message,/Бета-версии/);
  assert.doesNotMatch(message,/PANEL_DOWNLOAD_FAILED|Доступно: \?/);
  assert.equal(nodes['panel-update-apply'].disabled,true);
  assert.equal(nodes['panel-update-details'].hidden,true);
 }finally{Object.assign(global,original);}
});
test('download failure displays understandable Russian text with code in details only',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async(path,opts)=>{
  if(path==='/api/updates/panel/check')return {ok:false,status:502,json:async()=>({error_code:'PANEL_DOWNLOAD_FAILED'})};
  if(path==='/api/updates/panel/channel')return {ok:true,json:async()=>({channel:'experimental',allowed:['experimental','stable']})};
  return {ok:true,json:async()=>({ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'})};
 };
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await nodes['panel-update-check'].listeners.click();
  assert.match(nodes['panel-update-state'].textContent,/Не удалось загрузить сведения об обновлении с GitHub/);
  assert.doesNotMatch(nodes['panel-update-state'].textContent,/PANEL_DOWNLOAD_FAILED/);
  assert.equal(nodes['panel-update-details'].hidden,false);
  assert.equal(nodes['panel-update-error-code'].textContent,'PANEL_DOWNLOAD_FAILED');
  assert.equal(nodes['panel-update-apply'].disabled,true);
 }finally{Object.assign(global,original);}
});
test('a published channel that lost its index is a failure, not "not published yet"',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async(path,opts)=>{
  if(path==='/api/updates/panel/check')return {ok:false,status:502,json:async()=>({error_code:'PANEL_CHANNEL_INDEX_MISSING'})};
  if(path==='/api/updates/panel/channel')return {ok:true,json:async()=>({channel:'stable',allowed:['experimental','stable']})};
  return {ok:true,json:async()=>({ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'})};
 };
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await nodes['panel-update-check'].listeners.click();
  const text=nodes['panel-update-state'].textContent;
  assert.match(text,/канал уже опубликован, но файл индекса обновлений недоступен/);
  assert.doesNotMatch(text,/пока не выпущена|PANEL_CHANNEL_INDEX_MISSING/);
  assert.equal(nodes['panel-update-details'].hidden,false);
  assert.equal(nodes['panel-update-error-code'].textContent,'PANEL_CHANNEL_INDEX_MISSING');
 }finally{Object.assign(global,original);}
});
test('update phases are localized, not raw worker phase identifiers',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={},id='a'.repeat(24);
 global.document={getElementById:key=>nodes[key]||(nodes[key]={textContent:'',hidden:false,disabled:false,value:'',addEventListener(){}}),activeElement:null};
 global.sessionStorage={getItem:()=>id,setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>path==='/api/updates/panel/channel'?{channel:'experimental',allowed:['experimental','stable']}:{ID:id,State:'RUNNING',Phase:'download'}});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await new Promise(setImmediate);
  assert.match(nodes['panel-update-state'].textContent,/Загрузка пакета/);
  assert.doesNotMatch(nodes['panel-update-state'].textContent,/download/);
 }finally{Object.assign(global,original);}
});
test('panel success requires exact fresh runtime version and source',()=>{
 const op={ID:'a'.repeat(24),State:'OK',Version:'0.0.1~test16.a-1',SourceSHA:'b'.repeat(40),Gate:false};
 assert.equal(api.verifiedPanelReturn(op,{panel:{version:op.Version,source_sha:op.SourceSHA}}),true);
 for(const op2 of [{...op,State:'RUNNING'},{...op,Gate:true}])assert.equal(api.verifiedPanelReturn(op2,{panel:{version:op.Version,source_sha:op.SourceSHA}}),false);
 assert.equal(api.verifiedPanelReturn(op,{panel:{version:'old',source_sha:op.SourceSHA}}),false);
 assert.equal(api.verifiedPanelReturn(op,{panel:{version:op.Version,source_sha:'c'.repeat(40)}}),false);
});
test('lost apply response never accepts previous success as a new job',()=>{
 const old={ID:'a'.repeat(24),State:'OK'};assert.equal(api.acceptPanelOperation(old.ID,old,true),false);
 assert.equal(api.acceptPanelOperation(old.ID,{ID:'b'.repeat(24),State:'RUNNING'},true),true);
 assert.equal(api.acceptPanelOperation('',old,false),true);
 assert.equal(api.acceptPanelOperation('',{ID:'invalid',State:'OK'},true),false);
});
test('panel updater labels cover the same keys in RU and EN',()=>{
 assert.deepEqual(Object.keys(api.words.ru).sort(),Object.keys(api.words.en).sort());
});
test('a definite apply refusal is reported immediately, not polled to unverified',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout,window:global.window};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};global.window={confirm:()=>true};
 let applyPosts=0;
 global.fetch=async(path,opts)=>{
  if(path==='/api/updates/panel/channel')return {ok:true,json:async()=>({channel:'experimental',allowed:['experimental','stable']})};
  if(path==='/api/updates/panel/operation')return {ok:true,json:async()=>({state:'UNKNOWN',error_code:'NO_OPERATION'})};
  if(path==='/api/updates/panel/check')return {ok:true,json:async()=>({state:'OK',relation:'newer',installed_version:'0.1.0~beta.2-1',runtime_version:'0.1.0~beta.2-1',available_version:'0.1.0~beta.3-1',channel:'experimental'})};
  if(path==='/api/updates/panel/apply'){applyPosts++;return {ok:false,status:409,json:async()=>({error_code:'BUSY'})};}
  return {ok:true,json:async()=>({ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'})};
 };
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);
  await nodes['panel-update-check'].listeners.click();
  assert.equal(nodes['panel-update-apply'].disabled,false);
  await nodes['panel-update-apply'].listeners.click();
  const text=nodes['panel-update-state'].textContent;
  assert.match(text,/Обновление панели не завершено\. Причина: Сейчас выполняется другая операция\./);
  assert.doesNotMatch(text,/BUSY/);
  assert.equal(nodes['panel-update-details'].hidden,false);
  assert.equal(nodes['panel-update-error-code'].textContent,'BUSY');
  assert.equal(nodes['panel-update-apply'].disabled,true,'a consumed check must not allow a new install');
  assert.equal(applyPosts,1);
 }
 finally{Object.assign(global,original);}
});
test('interrupted update with the recovery gate names the SSH path without echoing itself',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',hidden:false,disabled:false,listeners:{},addEventListener(){}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>path==='/api/updates/panel/channel'?{channel:'experimental',allowed:['experimental','stable']}:{ID:'e'.repeat(24),State:'FAIL',Gate:true,ErrorCode:'PANEL_RECOVERY_REQUIRED'}});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await new Promise(setImmediate);
  const text=nodes['panel-update-state'].textContent;
  assert.match(text,/Обновление панели прервалось\. Продолжить установку из браузера невозможно\./);
  assert.equal((text.match(/прервал/g)||[]).length,1,'recovery text must not repeat "прервалось/прервано"');
 }
 finally{Object.assign(global,original);}
});
test('version check renders public forms without exposing internal package versions',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(ev,fn){this.listeners[ev]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async(path,options)=>({ok:true,json:async()=>{
  if(options&&options.method==='POST'&&path==='/api/updates/panel/check')return{state:'OK',relation:'newer',installed_version:'0.1.0~beta.1-1',runtime_version:'0.1.0~beta.1-1',available_version:'0.1.0~beta.2-1',channel:'experimental'};
  return {ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'};
 }});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);
  await nodes['panel-update-check'].listeners.click();
  await new Promise(setImmediate);
  const text=nodes['panel-update-state'].textContent;
  assert.match(text,/Установлено: v0\.1\.0-beta\.1\./);
  assert.match(text,/Запущено: v0\.1\.0-beta\.1\./);
  assert.match(text,/Доступно: v0\.1\.0-beta\.2\./);
  assert.doesNotMatch(text,/0\.1\.0~beta/);
 }
 finally{Object.assign(global,original);}
});
test('verified success announces the public version form',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};const id='a'.repeat(24);
 global.document={getElementById:key=>nodes[key]||(nodes[key]={textContent:'',addEventListener(){}})};
 global.sessionStorage={getItem:()=>id,setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>{
  if(path==='/api/components')return {panel:{version:'0.1.0~beta.2-1',source_sha:'b'.repeat(40)}};
  return {ID:id,State:'OK',Version:'0.1.0~beta.2-1',SourceSHA:'b'.repeat(40),Gate:false};
 }});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await new Promise(setImmediate);
  assert.match(nodes['panel-update-state'].textContent,/Запущена новая версия: v0\.1\.0-beta\.2\./);
  assert.doesNotMatch(nodes['panel-update-state'].textContent,/0\.1\.0~beta/);
 }
 finally{Object.assign(global,original);}
});
test('reload during an unconfirmed apply rejects the persisted previous job',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};const id='a'.repeat(24);let components=0;
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',addEventListener(){}})};
 global.sessionStorage={getItem:()=>`pending:${id}`,setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>{if(path==='/api/components'){components++;return {panel:{version:'v',source_sha:'b'.repeat(40)}};}return {ID:id,State:'OK',Version:'v',SourceSHA:'b'.repeat(40),Gate:false};}});
 try{api.mount({getLang:()=> 'en',isBusy:()=>false,onBusy(){}});await new Promise(setImmediate);assert.equal(components,0);assert.match(nodes['panel-update-state'].textContent,/Waiting for a new operation/);}
 finally{Object.assign(global,original);}
});
test('without stored ownership a historical success is not announced as a new update',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};let components=0;
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',addEventListener(){}})};
 global.sessionStorage={getItem(){throw Error('blocked')},setItem(){throw Error('blocked')},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>{if(path==='/api/components'){components++;return {panel:{version:'v',source_sha:'b'.repeat(40)}};}return {ID:'a'.repeat(24),State:'OK',Version:'v',SourceSHA:'b'.repeat(40),Gate:false};}});
 try{api.mount({getLang:()=> 'en',isBusy:()=>false,onBusy(){}});await new Promise(setImmediate);assert.equal(components,0);assert.match(nodes['panel-update-state'].textContent,/previous operation/i);}
 finally{Object.assign(global,original);}
});
test('a successful check with a newer version never claims no check has run',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(ev,fn){this.listeners[ev]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async(path,options)=>({ok:true,json:async()=>{
  if(options&&options.method==='POST'&&path==='/api/updates/panel/check')return{state:'OK',relation:'newer',installed_version:'a',runtime_version:'a',available_version:'b',channel:'experimental'};
  return {ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'};
 }});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);
  await nodes['panel-update-check'].listeners.click();
  await new Promise(setImmediate);
  const text=nodes['panel-update-state'].textContent;
  assert.match(text,/Доступно: b\./);
  assert.match(text,/Доступно обновление панели/);
  assert.doesNotMatch(text,/Обновления панели ещё не проверялись/);
  assert.equal(nodes['panel-update-apply'].disabled,false);
 }
 finally{Object.assign(global,original);}
});
test('channel selection follows server state and never enables apply by itself',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(ev,fn){this.listeners[ev]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>{
  if(path==='/api/updates/panel/channel')return {channel:'stable',build_channel:'experimental',allowed:['experimental','stable']};
  return {ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'};
 }});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await new Promise(setImmediate);
  assert.equal(nodes['panel-channel'].value,'stable');
  assert.equal(nodes['panel-channel-experimental'].hidden,false);
  assert.equal(nodes['panel-channel-stable'].hidden,false);
  assert.equal(nodes['panel-update-apply'].disabled,true);
 }
 finally{Object.assign(global,original);}
});
test('channel targets outside the server-allowed list are hidden from the selector',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(ev,fn){this.listeners[ev]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>{
  if(path==='/api/updates/panel/channel')return {channel:'experimental',build_channel:'experimental',allowed:['experimental']};
  return {ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'};
 }});
 try{
  api.mount({getLang:()=>'en',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await new Promise(setImmediate);
  assert.equal(nodes['panel-channel'].value,'experimental');
  assert.equal(nodes['panel-channel-experimental'].hidden,false);
  assert.equal(nodes['panel-channel-stable'].hidden,true);
 }
 finally{Object.assign(global,original);}
});
test('both channel directions are offered on any known build channel',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(ev,fn){this.listeners[ev]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:()=>'',setItem(){},removeItem(){}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>{
  if(path==='/api/updates/panel/channel')return {channel:'stable',build_channel:'stable',allowed:['experimental','stable']};
  return {ID:'f'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'NONE'};
 }});
 try{
  api.mount({getLang:()=>'en',isBusy:()=>false,onBusy(){}});
  await new Promise(setImmediate);await new Promise(setImmediate);
  assert.equal(nodes['panel-channel'].value,'stable');
  assert.equal(nodes['panel-channel-experimental'].hidden,false);
  assert.equal(nodes['panel-channel-stable'].hidden,false);
 }
 finally{Object.assign(global,original);}
});

test('verified success schedules exactly one reload and stores the verified identity',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={},store={},id='a'.repeat(24);
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}}),activeElement:null};
 global.sessionStorage={getItem:k=>store[k]??null,setItem:(k,v)=>{store[k]=v;},removeItem:k=>{delete store[k];}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 store['kas_panel_update_id']=id;
 global.fetch=async(path,opts)=>({ok:true,json:async()=>{
  if(path==='/api/updates/panel/channel')return {channel:'experimental',allowed:['experimental','stable']};
  if(path==='/api/components')return {panel:{version:'0.1.0~beta.4-1',source_sha:'c'.repeat(40)}};
  return {ID:id,State:'OK',Version:'0.1.0~beta.4-1',SourceSHA:'c'.repeat(40),Gate:false};
 }});
 let reloads=0;
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){},reload:()=>{reloads++;}});
  await new Promise(setImmediate);await new Promise(setImmediate);await new Promise(setImmediate);
  assert.match(nodes['panel-update-state'].textContent,/Запущена новая версия: v0\.1\.0-beta\.4/);
  assert.equal(reloads,1,'exactly one reload after verified success');
  const marker=JSON.parse(store['kas_updated_to']);
  assert.equal(marker.v,'0.1.0~beta.4-1');
  assert.equal(marker.s,'c'.repeat(40));
 }finally{Object.assign(global,original);}
});
test('failed, unverified and historical operations never reload',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const store={};
 const ops={
  fail:{ID:'a'.repeat(24),State:'FAIL',Gate:false,ErrorCode:'PANEL_OPKG_FAILED'},
  unverified:{ID:'a'.repeat(24),State:'OK',Gate:false,Version:'x',SourceSHA:'b'.repeat(40)},
  previous:{ID:'a'.repeat(24),State:'OK',Gate:false,Version:'v',SourceSHA:'b'.repeat(40)}
 };
 for(const [label,op] of Object.entries(ops)){
  const nodes={};
  global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(){}}),activeElement:null};
  global.sessionStorage={getItem:k=>store[k]??null,setItem:(k,v)=>{store[k]=v;},removeItem(){}};
  global.setTimeout=()=>1;global.clearTimeout=()=>{};
  global.fetch=async path=>({ok:true,json:async()=>{
   if(path==='/api/updates/panel/channel')return {channel:'experimental',allowed:['experimental','stable']};
   if(path==='/api/components')return {panel:{version:'v',source_sha:'b'.repeat(40)}};
   return op;
  }});
  let reloads=0;
  try{
   api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){},reload:()=>{reloads++;}});
   await new Promise(setImmediate);await new Promise(setImmediate);
   assert.equal(reloads,0,label+': must not reload');
   assert.equal(store['kas_updated_to'],undefined,label+': must not store marker');
  }finally{global.fetch=undefined;}
 }
 Object.assign(global,original);
});
test('post-reload marker shows the updated notice exactly once and is consumed',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};const store={'kas_updated_to':JSON.stringify({v:'0.1.0~beta.4-1',s:'c'.repeat(40)})};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',hidden:false,disabled:false,listeners:{},addEventListener(){}}),activeElement:null};
 global.sessionStorage={getItem:k=>store[k]??null,setItem:(k,v)=>{store[k]=v;},removeItem:k=>{delete store[k];}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 let componentsCalls=0;
 global.fetch=async path=>({ok:true,json:async()=>{
  if(path==='/api/components'){componentsCalls++;return {panel:{version:'0.1.0~beta.4-1',source_sha:'c'.repeat(40)}};}
  if(path==='/api/updates/panel/operation')return {state:'UNKNOWN',error_code:'NO_OPERATION'};
  return {channel:'experimental',allowed:['experimental','stable']};
 }});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){},reload(){throw Error('must never reload from the post-reload path');}});
  await new Promise(setImmediate);await new Promise(setImmediate);await new Promise(setImmediate);
  assert.match(nodes['panel-update-state'].textContent,/Панель обновлена до v0\.1\.0-beta\.4\. Интерфейс загружен заново\./);
  assert.equal(componentsCalls,1);
  assert.equal('kas_updated_to' in store,false,'marker consumed');
 }finally{Object.assign(global,original);}
});
test('post-reload marker with mismatched identity is dropped without a second reload',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout};
 const nodes={};const store={'kas_updated_to':JSON.stringify({v:'0.1.0~beta.4-1',s:'c'.repeat(40)})};
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',hidden:false,disabled:false,listeners:{},addEventListener(){}}),activeElement:null};
 global.sessionStorage={getItem:k=>store[k]??null,setItem:(k,v)=>{store[k]=v;},removeItem:k=>{delete store[k];}};
 global.setTimeout=()=>1;global.clearTimeout=()=>{};
 global.fetch=async path=>({ok:true,json:async()=>{
  if(path==='/api/components')return {panel:{version:'0.1.0~beta.2-1',source_sha:'c'.repeat(40)}};
  if(path==='/api/updates/panel/operation')return {state:'UNKNOWN',error_code:'NO_OPERATION'};
  return {channel:'experimental',allowed:['experimental','stable']};
 }});
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){},reload(){throw Error('must never reload twice');}});
  await new Promise(setImmediate);await new Promise(setImmediate);await new Promise(setImmediate);
  assert.doesNotMatch(nodes['panel-update-state'].textContent,/Панель обновлена до/);
  assert.equal('kas_updated_to' in store,false,'marker consumed even on mismatch');
 }finally{Object.assign(global,original);}
});
test('without sessionStorage a verified success never reloads (no loop protection means no reload)',async()=>{
 const original={document:global.document,sessionStorage:global.sessionStorage,fetch:global.fetch,setTimeout:global.setTimeout,clearTimeout:global.clearTimeout,window:global.window};
 const nodes={},id='a'.repeat(24);
 global.document={getElementById:id=>nodes[id]||(nodes[id]={textContent:'',value:'',hidden:false,disabled:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}}),activeElement:null};
 global.sessionStorage={getItem(){throw Error('blocked');},setItem(){throw Error('blocked');},removeItem(){}};
 // Microtask-driven timers so the post-apply poll chain actually runs.
 global.setTimeout=(fn,ms)=>{queueMicrotask(()=>fn());return 1;};global.clearTimeout=()=>{};
 global.window={confirm:()=>true};
 // Stateful backend: the previous op (id) exists; apply starts a NEW job
 // (id2) that first runs, then completes with a verified identity.
 const id2='b'.repeat(24);let applied=false,ranOnce=false;
 global.fetch=async(path,opts)=>{
  const method=(opts&&opts.method)||'GET';
  if(path==='/api/updates/panel/channel')return {ok:true,json:async()=>({channel:'experimental',allowed:['experimental','stable']})};
  if(path==='/api/updates/panel/check'&&method==='POST')return {ok:true,json:async()=>({state:'OK',relation:'newer',installed_version:'0.1.0~beta.3-1',runtime_version:'0.1.0~beta.3-1',available_version:'0.1.0~beta.4-1',channel:'experimental'})};
  if(path==='/api/updates/panel/operation')return {ok:true,json:async()=>{
   if(!applied)return {ID:id,State:'OK',Version:'0.1.0~beta.3-1',SourceSHA:'d'.repeat(40),Gate:false};
   if(!ranOnce){ranOnce=true;return {ID:id2,State:'RUNNING',Phase:'install',Version:'0.1.0~beta.4-1',SourceSHA:'c'.repeat(40),Gate:true};}
   return {ID:id2,State:'OK',Version:'0.1.0~beta.4-1',SourceSHA:'c'.repeat(40),Gate:false};
  }};
  if(path==='/api/updates/panel/apply'&&method==='POST'){applied=true;return {ok:true,json:async()=>({id:id2,state:'RUNNING'})};}
  if(path==='/api/components')return {ok:true,json:async()=>({panel:{version:'0.1.0~beta.4-1',source_sha:'c'.repeat(40)}})};
  return {ok:true,json:async()=>({channel:'experimental',allowed:['experimental','stable']})};
 };
 try{
  api.mount({getLang:()=>'ru',isBusy:()=>false,onBusy(){},reload(){throw Error('must not reload without sessionStorage');}});
  await new Promise(setImmediate);
  await nodes['panel-update-check'].listeners.click();
  await new Promise(setImmediate);
  assert.equal(nodes['panel-update-apply'].disabled,false);
  await nodes['panel-update-apply'].listeners.click();
  await new Promise(setImmediate);await new Promise(setImmediate);await new Promise(setImmediate);
  assert.match(nodes['panel-update-state'].textContent,/Запущена новая версия: v0\.1\.0-beta\.4/);
 }finally{Object.assign(global,original);}
});
