const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');const path=require('node:path');
const root=path.join(__dirname,'../web');const app=fs.readFileSync(path.join(root,'app.js'),'utf8');const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
const start=app.indexOf('const words='),end=app.indexOf('\nlet lang=',start);const words=vm.runInNewContext('('+app.slice(start+'const words='.length,end).trim().replace(/;$/,'')+')');
test('sidebar version comes from validated /api/components and footer keeps SHA',()=>{
 assert.match(html,/id="sidebar-version"/);assert.match(html,/id="panel-build"/);
 assert.match(app,/set\('sidebar-version','KAS Web '\+\(panel.version/);
 assert.match(app,/set\('panel-build','KAS Web '\+\(panel.version/);
 assert.match(app,/componentsData=response.ok&&validComponents\(data\)\?data:null/);
});
test('script install absence informational; runtime/updater/opkg separate',()=>{
 for(const lang of ['ru','en']){
  assert.match(words[lang].coreAbsentHelp,/kas-core\.ipk/);
  assert.match(words[lang].updateSamePackage,/opkg/);
  assert.match(words[lang].updateAvailable,/runtime/);
  assert.match(words[lang].updatePackageMetadata,/opkg/);
 }
 assert.doesNotMatch(app,/opkg install kas-core/);
});
