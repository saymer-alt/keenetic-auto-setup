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
