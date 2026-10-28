const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
test('CI can extract complete RU/EN dictionaries and every static binding',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
 const start=source.indexOf('const words='),end=source.indexOf('\nlet lang=',start);
 assert.ok(start>=0&&end>start);
 const expression=source.slice(start+'const words='.length,end).trim().replace(/;$/,'');
 const dictionaries=vm.runInNewContext('('+expression+')');
 assert.equal(JSON.stringify(Object.keys(dictionaries.ru).sort()),JSON.stringify(Object.keys(dictionaries.en).sort()));
 const bindings=[...source.matchAll(/for\(const \[id,key\] of (\[[^\n]+\])\)/g)].flatMap(match=>Array.from(vm.runInNewContext(match[1]),pair=>pair[1]));
 const used=new Set([...bindings,...[...source.matchAll(/\bt\('([^']+)'/g)].map(match=>match[1])]);
 for(const key of used)for(const locale of ['ru','en'])assert.equal(typeof dictionaries[locale][key],'string',locale+' missing '+key);
 assert.equal(typeof dictionaries.ru.settingsEntwareHelp,'string');
});
