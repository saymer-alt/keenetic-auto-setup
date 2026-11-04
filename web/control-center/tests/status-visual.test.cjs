const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const segment=source.slice(source.indexOf('function validStatus('),source.indexOf('function doctorResultText('));
function harness(){return vm.runInNewContext('let statusData=null;const t=k=>k;'+segment+';({validStatus,serviceTone,serviceText,set:data=>statusData=data})',{Date,Number});}
test('service colors require fresh positive runtime evidence',()=>{
 const h=harness(),timestamp=new Date().toISOString();
 assert.equal(h.serviceTone('mihomo'),'unverified');
 assert.equal(h.validStatus({timestamp:'2021-01-01T00:00:00Z',runtime:{}}),false);
 assert.equal(h.validStatus({timestamp,runtime:{}}),true);
 for(const state of ['running','stopped','absent','unknown']){
  h.set({timestamp,runtime:{mihomo:{state}}});assert.equal(h.serviceTone('mihomo'),state);
  assert.equal(h.serviceText('mihomo').startsWith({running:'✓',stopped:'✕',absent:'∅',unknown:'?'}[state]),true);
 }
 h.set({timestamp,runtime:{mihomo:{state:'invalid'}}});assert.equal(h.serviceTone('mihomo'),'unknown');
 h.set({timestamp,runtime:{}});assert.equal(h.serviceTone('mihomo'),'unknown');
 h.set(null);assert.equal(h.serviceTone('mihomo'),'unverified');
});
