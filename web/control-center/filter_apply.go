package main

// Stage 2 of the filter editor: explicit application of the previewed
// exclude-filter change through the canonical config-import.sh transaction.
// The shell importer owns lock/validate/backup/commit/rollback; this adapter
// only guards the request, stages two private temp files (candidate and the
// operator-approved source snapshot) and hands the snapshot to the importer's
// opt-in KAS_EXPECTED_SOURCE gate. The gate proves, under the lifecycle lock
// and before Mihomo is stopped, that the on-disk config is still byte-for-byte
// the version the operator approved. A change anywhere between preview and the
// transaction aborts with a clear error and never applies the stale variant.
import (
 "bytes"
 "context"
 "crypto/rand"
 "encoding/hex"
 "encoding/json"
 "errors"
 "io"
 "net/http"
 "os"
 "strings"
 "time"
 "unicode/utf8"
)

const maxFilterRequestBody=64*1024
type filterApplyResponse struct{
 Provider string `json:"provider"`
 Applied bool `json:"applied"`
 Reason string `json:"reason,omitempty"`
 SourceSHA string `json:"source_sha,omitempty"`
 OperationID string `json:"operation_id,omitempty"`
}
func(a *app)releaseImportSlot(){
 a.mu.Lock();a.importRunning=false;a.mu.Unlock()
}
func(a *app)verifyFilterNames(ctx context.Context,provider string,names []string)string{
 snapshot,err:=a.providers.snapshot(ctx)
 if err!=nil{return "MIHOMO_UNAVAILABLE"}
 var parsed struct{Providers map[string]struct{Proxies []struct{Name string `json:"name"`} `json:"proxies"`} `json:"providers"`}
 if json.Unmarshal(snapshot,&parsed)!=nil{return "MIHOMO_RESPONSE_INVALID"}
 entry,ok:=parsed.Providers[provider]
 if !ok{return "PROVIDER_NOT_LOADED"}
 available:=map[string]bool{}
 for _,node:=range entry.Proxies{available[node.Name]=true}
 for _,name:=range names{if !available[name]{return "NODE_NOT_LOADED"}}
 return ""
}
// One private 0600 temp file with an unpredictable O_EXCL name; the caller
// removes it. No client-controlled path is ever accepted.
func stagePrivateTemp(prefix string,data []byte)(string,error){
 f,err:=os.CreateTemp("/tmp",prefix)
 if err!=nil{return "",err}
 path:=f.Name()
 if err:=f.Chmod(0600);err!=nil{_ = f.Close();_ = os.Remove(path);return "",err}
 if _,err=f.Write(data);err!=nil{_ = f.Close();_ = os.Remove(path);return "",err}
 if err=f.Close();err!=nil{_ = os.Remove(path);return "",err}
 return path,nil
}
func(a *app)handleFilterApply(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodPost{filterError(w,405,"METHOD_NOT_ALLOWED");return}
 if a.providers==nil{filterError(w,404,"EDITOR_DISABLED");return}
 if len(a.importer)==0{filterError(w,503,"IMPORTER_UNAVAILABLE");return}
 if !a.directHost(r.Host) && r.Host!=a.proxyHost{filterError(w,403,"REQUEST_BLOCKED");return}
 if r.Header.Get("Origin")!=a.expectedOrigin(r.Host)||
    r.Header.Get("Content-Type")!="application/json"||
    r.Header.Get("X-KAS-Confirm")!="apply"{
  filterError(w,403,"REQUEST_BLOCKED");return
 }
 if site:=r.Header.Get("Sec-Fetch-Site");site!=""&&site!="same-origin"{filterError(w,403,"REQUEST_BLOCKED");return}
 r.Body=http.MaxBytesReader(w,r.Body,maxFilterRequestBody)
 decoder:=json.NewDecoder(r.Body);decoder.DisallowUnknownFields()
 var request filterEditRequest
 if err:=decoder.Decode(&request);err!=nil{filterError(w,400,"INVALID_REQUEST");return}
 var extra any
 if err:=decoder.Decode(&extra);!errors.Is(err,io.EOF){filterError(w,400,"INVALID_REQUEST");return}
 if request.Provider==""||len(request.Provider)>256||len(request.SourceSHA)!=64||
   strings.Trim(request.SourceSHA,"0123456789abcdef")!=""{
  filterError(w,400,"INVALID_REQUEST");return
 }
 if request.Clear&&len(request.Names)!=0{filterError(w,400,"INVALID_REQUEST");return}
 for _,name:=range request.Names{
  if name==""||strings.TrimSpace(name)==""||len(name)>256||!utf8.ValidString(name){
   filterError(w,400,"INVALID_REQUEST");return
  }
 }
 // One mutating operation at a time, shared with YAML import and Doctor.
 a.mu.Lock()
 if a.panelUpdateBusy() || a.importRunning||a.running||a.shuttingDown{
  a.mu.Unlock();filterError(w,409,"BUSY");return
 }
 a.importRunning=true
 a.mu.Unlock()
 fail:=func(code int,label string){
  a.releaseImportSlot();filterError(w,code,label)
 }
 // Pre-flight freshness check. The authoritative proof happens later under
 // the lifecycle lock inside config-import.sh via KAS_EXPECTED_SOURCE.
 data,err:=a.filterConfig()
 if err!=nil{fail(503,"CONFIG_UNAVAILABLE");return}
 digest:=filterSourceDigest(data)
 if digest!=request.SourceSHA{fail(409,"CONFIG_CHANGED");return}
 if !request.Clear{
  // Do not accept node names invented by a browser: verify against the live
  // sanitized Mihomo provider snapshot. Clearing needs no names on purpose:
  // already excluded nodes may be absent from the runtime listing.
  ctx,cancel:=context.WithTimeout(r.Context(),7*time.Second);defer cancel()
  if code:=a.verifyFilterNames(ctx,request.Provider,request.Names);code!=""{
   if code=="MIHOMO_UNAVAILABLE"{fail(502,code)}else{fail(422,code)}
   return
  }
 }
 candidate,_,_,err:=patchProviderFilter(data,request.Provider,request.Names,request.Clear)
 if err!=nil{fail(422,"UNSUPPORTED_OR_INVALID_FILTER");return}
 if bytes.Equal(candidate,data){
  // Nothing to do (filter already identical, or clearing when none set):
  // never restart Mihomo for a no-op.
  a.releaseImportSlot()
  writeFilterJSON(w,200,filterApplyResponse{Provider:request.Provider,Applied:false,
   Reason:"NO_CHANGE",SourceSHA:digest})
  return
 }
 candidatePath,err:=stagePrivateTemp(".kas-filter-*.yaml",candidate)
 if err!=nil{fail(503,"STAGING_FAILED");return}
 sourcePath,err:=stagePrivateTemp(".kas-filter-src-*.yaml",data)
 if err!=nil{os.Remove(candidatePath);fail(503,"STAGING_FAILED");return}
 idbytes:=make([]byte,12)
 if _,err=rand.Read(idbytes);err!=nil{
  os.Remove(candidatePath);os.Remove(sourcePath);fail(503,"STAGING_FAILED");return
 }
 entry:=importStatus{ID:hex.EncodeToString(idbytes),State:"RUNNING",Time:now(),
  Source:"bundled config-import.sh (filter apply)"}
 a.mu.Lock();a.importResult=entry;a.mu.Unlock()
 go func(){
  defer os.Remove(candidatePath)
  defer os.Remove(sourcePath)
  // The importer's own transaction and expected-source gates are
  // authoritative; their output is discarded, never exposed.
  exit,runErr:=a.runImport(a.importer,candidatePath,[]string{"KAS_EXPECTED_SOURCE="+sourcePath})
  result:=entry;result.Time=now();result.ExitCode=&exit
  if runErr!=nil||exit!=0{result.State="FAIL";result.ErrorCode="FILTER_APPLY_FAILED"}else{result.State="OK"}
  a.mu.Lock();a.importResult=result;a.importRunning=false;a.mu.Unlock()
 }()
 writeFilterJSON(w,http.StatusAccepted,entry)
}
