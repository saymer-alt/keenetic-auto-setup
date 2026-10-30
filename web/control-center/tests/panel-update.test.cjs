const {test}=require('node:test');const assert=require('node:assert/strict');
const api=require('../web/panel-update.js');
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
