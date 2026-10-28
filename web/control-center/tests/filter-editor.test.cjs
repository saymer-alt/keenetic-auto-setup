// Run the real offline UI with a small DOM/fetch fixture; no router or browser dependency.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

class Element {
 constructor(){this.children=[];this.style={};this.disabled=false;this.checked=false;this.value='';this.textContent='';this.files=[];}
 replaceChildren(...children){this.children=children;}
 appendChild(child){this.children.push(child);return child;}
 addEventListener(){}
 setAttribute(){}
 querySelectorAll(){return this.children.flatMap(label=>label.children||[]).filter(x=>x.checked);}
}
const response=(status,data)=>({ok:status>=200&&status<300,status,json:async()=>data});
function ui(namesResult,inspectStatus=200,operationState='UNKNOWN'){
 const elements=new Map();
 const el=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
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
   if(url==='/api/filter/providers')return response(inspectStatus,{source_sha:'a'.repeat(64),providers:[{name:'P',http:true,has_filter:true,existing_filter:'Old'}]});
   if(url==='/api/providers/names'){
    if(namesResult instanceof Error)throw namesResult;
    return namesResult;
   }
   if(url==='/api/filter/preview')return response(200,{existing_filter:'Old',proposed_filter:''});
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
 await app.run('previewFilterChange(true)');
 assert.equal(app.el('filter-apply').disabled,false);
 await app.run('applyFilterChange()');
 const request=app.requests.find(x=>x.url==='/api/filter/apply');
 assert.deepEqual(JSON.parse(request.options.body),{provider:'P',names:[],clear:true,source_sha:'a'.repeat(64)});
});

test('failed inspection disables all changes even when names loaded',async()=>{
 const app=ui(response(200,{providers:{P:{proxies:[{name:'X'}]}}}),503);
 await app.run('loadFilterEditor()');
 for(const id of ['filter-clear','filter-preview','filter-apply'])assert.equal(app.el(id).disabled,true);
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
 await app.run('previewFilterChange(true)');
 await app.run('applyFilterChange()');
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
