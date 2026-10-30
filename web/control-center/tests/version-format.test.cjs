// publicVersion exists in both app.js and panel-update.js on purpose: the two
// files are self-contained (browser load order and the offline test harness).
// This suite pins both implementations to identical, purely presentational behavior.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');

function extract(file){
 const source=fs.readFileSync(path.join(__dirname,'../web',file),'utf8');
 const match=source.match(/function publicVersion\(raw\)\{[\s\S]*?\n\s*\}/);
 assert.ok(match,file+' contains publicVersion');
 return match[0].split('\n').map(line=>line.replace(/^\s+/,'')).join('\n');
}
const body=extract('app.js');
test('app.js and panel-update.js ship the same publicVersion implementation',()=>{
 assert.equal(extract('panel-update.js'),body);
});
const publicVersion=vm.runInNewContext('('+body.replace('function publicVersion(raw){','function (raw){')+')');
test('beta IPK versions render the agreed public v-form',()=>{
 assert.equal(publicVersion('0.1.0~beta.2-1'),'v0.1.0-beta.2');
 assert.equal(publicVersion('0.1.0~beta.3-1'),'v0.1.0-beta.3'); // next beta: no hardcoding
 assert.equal(publicVersion('0.1.0~beta.2'),'v0.1.0-beta.2');
 assert.equal(publicVersion('0.0.1~test44.9c715283d525-1'),'v0.0.1-test44.9c715283d525'); // test builds stay faithful
});
test('stable and future versions render without the packaging revision',()=>{
 assert.equal(publicVersion('0.1.0-1'),'v0.1.0');
 assert.equal(publicVersion('0.1.0'),'v0.1.0');
 assert.equal(publicVersion('1.8.2-1'),'v1.8.2');
});
test('already public versions never gain a second v',()=>{
 assert.equal(publicVersion('v0.1.0-beta.2'),'v0.1.0-beta.2');
 assert.equal(publicVersion('v1.8.0'),'v1.8.0');
 assert.equal(publicVersion('V0.1.0'),'V0.1.0');
});
test('development and unknown or corrupted values pass through unchanged',()=>{
 assert.equal(publicVersion('development'),'development');
 assert.equal(publicVersion(''),'');
 assert.equal(publicVersion('?'),'?');
 assert.equal(publicVersion('SECRET-TOKEN'),'SECRET-TOKEN');
 assert.equal(publicVersion('0.1.0~beta.2-1 '),'v0.1.0-beta.2');
 assert.equal(publicVersion(undefined),undefined);
 assert.equal(publicVersion(null),null);
});
test('formatting is pure, single-argument and locale-independent',()=>{
 const value='0.1.0~beta.2-1';
 assert.equal(publicVersion(value),'v0.1.0-beta.2');
 assert.equal(value,'0.1.0~beta.2-1');
 assert.equal(publicVersion.length,1);
});
test('RU and EN templates interpolate the same formatted value',()=>{
 const api=require('../web/panel-update.js');
 const params={installed:publicVersion('0.1.0~beta.2-1'),runtime:publicVersion('0.1.0~beta.2-1'),available:publicVersion('0.1.0~beta.3-1'),channel:'experimental'};
 const render=(locale,key)=>api.words[locale][key].replace(/\{(\w+)\}/g,(_,k)=>String(params[k]??''));
 for(const locale of ['ru','en']){
  assert.match(render(locale,'available'),/Установлено: v0\.1\.0-beta\.2\.|Installed: v0\.1\.0-beta\.2\./);
  assert.match(render(locale,'available'),/Доступно: v0\.1\.0-beta\.3\.|Available: v0\.1\.0-beta\.3\./);
  assert.doesNotMatch(render(locale,'available'),/0\.1\.0~beta/);
  assert.doesNotMatch(render(locale,'available'),/vv/);
 }
});
