package main

// This stage-2 adapter provides ONE allowlisted KAS action: applying a complete
// YAML file via the canonical config-import.sh. The shell script owns all
// validation, maintenance locking, single-Mihomo checks and rollback.
import (
 "bytes"
 "crypto/rand"
 "encoding/hex"
 "encoding/json"
 "errors"
 "io"
 "net/http"
 "os"
 "os/exec"
 "strings"
 "unicode/utf8"
)

const maxYAMLBytes = 1024 * 1024

type importStatus struct {
 ID string `json:"id,omitempty"`
 State string `json:"state"`
 Time string `json:"timestamp"`
 Source string `json:"source,omitempty"`
 ExitCode *int `json:"exit_code,omitempty"`
 ErrorCode string `json:"error_code,omitempty"`
}

// The result never includes user YAML, URLs, credentials, paths or CLI output.
// The importer may print sensitive diagnostics; even heuristic redaction is
// insufficient for write operations, so stdout/stderr are intentionally not
// exposed through HTTP and are discarded rather than logged.
func respondImport(w http.ResponseWriter,code int,s importStatus){
 w.Header().Set("Content-Type","application/json; charset=utf-8")
 w.Header().Set("Cache-Control","no-store")
 w.Header().Set("X-Content-Type-Options","nosniff")
 w.WriteHeader(code)
 _ = jsonEncodeImport(w,s)
}
func jsonEncodeImport(w io.Writer,s importStatus)error{
 return json.NewEncoder(w).Encode(s)
}
func importCommand(script []byte,path string)(int,error){
 cmd:=exec.Command("sh","-s","--",path)
 cmd.Stdin=bytes.NewReader(script)
 cmd.Stdout=io.Discard
 cmd.Stderr=io.Discard
 // Deliberately not tied to HTTP request context: closing the browser must
 // not SIGKILL the shell in the middle of KAS's stop/backup/rollback transaction.
 // A stuck importer is reported as RUNNING until manually investigated.
 err:=cmd.Run()
 if err==nil{return 0,nil}
 var exitErr *exec.ExitError
 if errors.As(err,&exitErr){return exitErr.ExitCode(),err}
 return -1,err
}
func validYAMLBody(b []byte)bool{
 if len(b)==0||len(b)>maxYAMLBytes||!utf8.Valid(b)||bytes.IndexByte(b,0)>=0{return false}
 // Fast project contract guard. Canonical importer independently re-checks it.
 for _,line:=range strings.Split(string(b),"\n"){
  line=strings.TrimSuffix(line,"\r")
  line=strings.TrimLeft(line," \t")
  if !strings.HasPrefix(line,"mixed-port:"){continue}
  rest:=strings.TrimSpace(strings.TrimPrefix(line,"mixed-port:"))
  if rest=="7890"||strings.HasPrefix(rest,"7890 #"){return true}
 }
 return false
}
func (a *app)handleImportStatus(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodGet{http.Error(w,"method not allowed",http.StatusMethodNotAllowed);return}
 a.mu.Lock()
 v:=a.importResult
 a.mu.Unlock()
 if v.State==""{v=importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"NO_OPERATION"}}
 respondImport(w,http.StatusOK,v)
}
func (a *app)handleImport(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodPost{http.Error(w,"method not allowed",http.StatusMethodNotAllowed);return}
 if r.Header.Get("Origin")!="http://"+a.host ||
  r.Header.Get("Content-Type")!="application/x-yaml" ||
  r.Header.Get("X-KAS-Confirm")!="apply"{
  respondImport(w,http.StatusForbidden,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"REQUEST_BLOCKED"});return
 }
 if site:=r.Header.Get("Sec-Fetch-Site");site!=""&&site!="same-origin"{
  respondImport(w,http.StatusForbidden,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"REQUEST_BLOCKED"});return
 }
 if len(a.importer)==0{
  respondImport(w,http.StatusServiceUnavailable,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"IMPORTER_UNAVAILABLE"});return
 }
 if r.ContentLength>maxYAMLBytes{
  respondImport(w,http.StatusRequestEntityTooLarge,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"FILE_TOO_LARGE"});return
 }
 r.Body=http.MaxBytesReader(w,r.Body,maxYAMLBytes+1)
 body,err:=io.ReadAll(r.Body)
 if err!=nil||len(body)>maxYAMLBytes{
  respondImport(w,http.StatusRequestEntityTooLarge,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"FILE_TOO_LARGE"});return
 }
 if !validYAMLBody(body){
  respondImport(w,http.StatusBadRequest,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"INVALID_YAML"});return
 }
 // Do not queue imports or start a second importer/Doctor.
 a.mu.Lock()
 if a.importRunning||a.running{
  a.mu.Unlock()
  respondImport(w,http.StatusConflict,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"BUSY"});return
 }
 a.importRunning=true
 a.mu.Unlock()

 // A fixed location, unpredictable O_EXCL filename, private permissions and
 // immediate cleanup prevent browsing or lingering copies of subscription URLs.
 // No path is accepted from the HTTP client.
 f,err:=os.CreateTemp("/tmp",".kas-import-*.yaml")
 if err!=nil{
  a.mu.Lock();a.importRunning=false;a.mu.Unlock()
  respondImport(w,http.StatusServiceUnavailable,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"STAGING_FAILED"});return
 }
 path:=f.Name()
 if err:=f.Chmod(0600);err!=nil{_ = f.Close();_ = os.Remove(path);a.mu.Lock();a.importRunning=false;a.mu.Unlock();respondImport(w,http.StatusServiceUnavailable,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"STAGING_FAILED"});return}
 _,err=f.Write(body)
 if err==nil{err=f.Close()}else{_ = f.Close()}
 if err!=nil{_ = os.Remove(path);a.mu.Lock();a.importRunning=false;a.mu.Unlock();respondImport(w,http.StatusServiceUnavailable,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"STAGING_FAILED"});return}
 // The handler no longer retains the uploaded content.
 body=nil
 idbytes:=make([]byte,12)
 if _,err=rand.Read(idbytes);err!=nil{_ = os.Remove(path);a.mu.Lock();a.importRunning=false;a.mu.Unlock();respondImport(w,http.StatusServiceUnavailable,importStatus{State:"UNKNOWN",Time:now(),ErrorCode:"STAGING_FAILED"});return}
 entry:=importStatus{ID:hex.EncodeToString(idbytes),State:"RUNNING",Time:now(),Source:"bundled config-import.sh"}
 a.mu.Lock()
 a.importResult=entry
 a.mu.Unlock()
 go func(entry importStatus){
  defer os.Remove(path)
  // The importer's own preconditions and transaction are authoritative.
  exit,runErr:=a.runImport(a.importer,path)
  entry.Time=now()
  entry.ExitCode=&exit
  if runErr!=nil{
   entry.State="FAIL"
   entry.ErrorCode="IMPORT_FAILED"
  }else{entry.State="OK"}
  a.mu.Lock()
  a.importResult=entry
  a.importRunning=false
  a.mu.Unlock()
 }(entry)
 respondImport(w,http.StatusAccepted,entry)
}
