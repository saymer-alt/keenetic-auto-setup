const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const segment=source.slice(source.indexOf('function statusMessageKey('),source.indexOf('function doctorResultText('));
function harness(){return vm.runInNewContext('let statusData=null;const t=k=>k;'+segment+';({statusMessageKey,validStatus,serviceTone})',{Date,Number});}
test('stale and unverifiable status snapshots share one readable message, not a raw token',()=>{
 const h=harness();
 // Both internal tokens (the staleness interval and the rejected /api/status
 // payload) map to the same localized refresh prompt; other codes keep the
 // generic "could not refresh" text with the code interpolated.
 assert.equal(h.statusMessageKey('INVALID_OR_STALE_RESPONSE'),'statusStale');
 assert.equal(h.statusMessageKey('STALE_RESPONSE'),'statusStale');
 assert.equal(h.statusMessageKey('HTTP_503'),'statusError');
 assert.equal(h.statusMessageKey('UNKNOWN'),'statusError');
 // draw() routes status errors through the mapping; no literal token comparison remains.
 assert.ok(source.includes('statusMessageKey(statusError)'),'draw() must use statusMessageKey');
 assert.ok(!source.includes("statusError==='STALE_RESPONSE'"),'raw token comparison must be gone');
});
test('unverifiable status still prevents confirmed process colors',()=>{
 const h=harness();
 // Without an accepted snapshot no runtime state exists: the tone stays unverified.
 assert.equal(h.validStatus({timestamp:'2021-01-01T00:00:00Z',runtime:{}}),false);
 assert.equal(h.validStatus(null),false);
 assert.equal(h.serviceTone('mihomo'),'unverified');
});
