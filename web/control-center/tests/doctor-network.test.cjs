const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const segment=source.slice(source.indexOf('function doctorErrorCode('),source.indexOf('function validComponents('));
// Host intrinsics are passed in: the sandbox is a separate realm, so a host
// TypeError would otherwise fail `e instanceof TypeError` inside the segment.
const h=vm.runInNewContext('let doctorData=null;const t=k=>k;'+segment+';setDoctor=d=>doctorData=d;({doctorErrorCode,doctorResultText,setDoctor})',{Date,Number,TypeError,Error});
test('an unreachable Doctor API reports a localized connection failure, not a JS exception',()=>{
 // Browser fetch rejects with TypeError; it must become the fixed machine code.
 assert.equal(h.doctorErrorCode(new TypeError('Failed to fetch')),'NETWORK_ERROR');
 assert.equal(h.doctorErrorCode(new TypeError('NetworkError when attempting to fetch resource')),'NETWORK_ERROR');
 // Non-network failures keep their string form (shown as a code, no invention).
 assert.equal(h.doctorErrorCode(new Error('HTTP_502')),'Error: HTTP_502');
 // runDoctor() must normalize the caught error through the mapper.
 assert.ok(source.includes('error_code:doctorErrorCode(e)'),'runDoctor must map the caught error');
 h.setDoctor({error_code:'NETWORK_ERROR',exit_code:undefined,details:''});
 assert.equal(h.doctorResultText(),'doctorNetworkError');
});
test('no fabricated exit code and no raw TypeError in the localized network message',()=>{
 // The NETWORK_ERROR branch resolves before the failed branch, so no exit code
 // is interpolated for a request that never completed.
 h.setDoctor({error_code:'NETWORK_ERROR',exit_code:undefined,details:''});
 assert.equal(h.doctorResultText(),'doctorNetworkError');
 assert.notEqual(h.doctorResultText(),'failed');
});
test('machine codes from the API still use the existing failed-state text',()=>{
 h.setDoctor({error_code:'HTTP_502',exit_code:2,details:''});
 assert.equal(h.doctorResultText(),'failed');
 h.setDoctor({error_code:'TIMEOUT',exit_code:undefined,details:''});
 assert.equal(h.doctorResultText(),'failed');
});
