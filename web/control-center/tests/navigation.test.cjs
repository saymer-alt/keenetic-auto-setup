const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8');
const names=['overview','subscriptions','configuration','diagnostics','settings'];
function panel(){
 const elements=new Map();let active=null,draws=0;
 for(const id of [...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]))elements.set(id,{id,hidden:false,attrs:{},handlers:{},dataset:{},value:'',addEventListener(e,fn){this.handlers[e]=fn;},setAttribute(k,v){this.attrs[k]=v;},removeAttribute(k){delete this.attrs[k];},focus(){active=this.id;}});
 const el=id=>{assert.ok(elements.has(id),'missing actual HTML id '+id);return elements.get(id);};
 const buttons=names.map(name=>{const button=el('nav-'+name);button.dataset.view=name;return button;});
 const configuration=el('yaml-paste');configuration.value='private YAML stays in memory';
 const context={document:{documentElement:{dataset:{}},getElementById:el,querySelectorAll:()=>buttons},window:{kasDraw(){draws++;}}};
 vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/navigation.js'),'utf8'),context);
 return {el,context,active:()=>active,draws:()=>draws,click:name=>el('nav-'+name).handlers.click({preventDefault(){}})};
}
test('navigation exposes exactly one real view and preserves form data',()=>{
 const app=panel();
 for(const name of names){
  app.click(name);
  assert.equal(app.context.document.documentElement.dataset.view,name);
  assert.deepEqual(names.filter(n=>!app.el('view-'+n).hidden),[name]);
  assert.equal(app.el('nav-'+name).attrs['aria-current'],'page');
  assert.equal(app.el('yaml-paste').value,'private YAML stays in memory');
  assert.equal(app.active(),'content');
 }
 assert.equal(app.draws(),6);
});
test('keyboard navigation wraps, supports Home/End and ignores unrelated keys',()=>{
 const app=panel();
 const key=(name,key)=>app.el('view-nav').handlers.keydown({target:app.el('nav-'+name),key,preventDefault(){}});
 key('overview','ArrowLeft');assert.equal(app.active(),'nav-settings');
 key('settings','ArrowRight');assert.equal(app.active(),'nav-overview');
 key('overview','End');assert.equal(app.active(),'nav-settings');
 key('settings','Home');assert.equal(app.active(),'nav-overview');
 const draws=app.draws();key('overview','Tab');assert.equal(app.draws(),draws);
});
