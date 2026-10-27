package main

import (
 "bytes"
 "errors"
 "io"
 "net/http"
 "net/http/httptest"
 "os"
 "strings"
 "sync"
 "testing"
 "time"
)

func importReq(handler http.Handler,origin,ctype,confirm string,body []byte)*httptest.ResponseRecorder{
 req:=httptest.NewRequest(http.MethodPost,"http://127.0.0.1:18081/api/config/import",bytes.NewReader(body))
 req.Host="127.0.0.1:18081"
 req.Header.Set("Origin",origin)
 req.Header.Set("Content-Type",ctype)
 req.Header.Set("X-KAS-Confirm",confirm)
 w:=httptest.NewRecorder();handler.ServeHTTP(w,req);return w
}
func operation(a *app)importStatus{
 a.mu.Lock();defer a.mu.Unlock();return a.importResult
}
func untilCompleted(t *testing.T,a *app)importStatus{
 t.Helper()
 deadline:=time.Now().Add(2*time.Second)
 for time.Now().Before(deadline){
  v:=operation(a);if v.State=="OK"||v.State=="FAIL"{return v}
  time.Sleep(5*time.Millisecond)
 }
 t.Fatal("operation timed out in test")
 return importStatus{}
}
func TestImportRejectsInvalidAndCrossOrigin(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil);a.importer=[]byte("exit 0")
 h:=a.handler()
 yaml:=[]byte("mixed-port: 7890\nproxies: []\n")
 tests:=[]struct{origin,ctype,confirm string; body []byte;want int}{
  {"http://attacker.example","application/x-yaml","apply",yaml,403},
  {"http://127.0.0.1:18081","text/plain","apply",yaml,403},
  {"http://127.0.0.1:18081","application/x-yaml","",yaml,403},
  {"http://127.0.0.1:18081","application/x-yaml","apply",nil,400},
  {"http://127.0.0.1:18081","application/x-yaml","apply",[]byte("mixed-port: 1234"),400},
  {"http://127.0.0.1:18081","application/x-yaml","apply",[]byte("mixed-port: 7890\nhello:\x00"),400},
  {"http://127.0.0.1:18081","application/x-yaml","apply",[]byte{0xff,0xfe},400},
  {"http://127.0.0.1:18081","application/x-yaml","apply",bytes.Repeat([]byte("a"),maxYAMLBytes+1),413},
 }
 for i,tc:=range tests{
  res:=importReq(h,tc.origin,tc.ctype,tc.confirm,tc.body)
  if res.Code!=tc.want{t.Fatalf("case %d status %d expected %d body=%s",i,res.Code,tc.want,res.Body)}
 }
 if operation(a).State!=""{t.Fatal("rejected payload started import")}
}
func TestImportSuccessfulPrivateStagingAndDuplicate(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil)
 a.importer=[]byte("canonical test script")
 started:=make(chan struct{})
 release:=make(chan struct{})
 var once sync.Once
 a.runImport=func(script []byte,path string)(int,error){
  if string(script)!="canonical test script"{t.Error("unexpected importer")}
  st,err:=os.Stat(path);if err!=nil{t.Error(err);return -1,err}
  if st.Mode().Perm()!=0600{t.Errorf("temp permissions = %o",st.Mode().Perm())}
  b,err:=os.ReadFile(path);if err!=nil{t.Error(err)}
  if string(b)!="mixed-port: 7890\nproxies:\n  - name: SECRET-SUBSCRIPTION-KEY\n"{t.Errorf("body changed")}
  once.Do(func(){close(started)})
  <-release
  return 0,nil
 }
 secret:=[]byte("mixed-port: 7890\nproxies:\n  - name: SECRET-SUBSCRIPTION-KEY\n")
 h:=a.handler()
 r:=importReq(h,"http://127.0.0.1:18081","application/x-yaml","apply",secret)
 if r.Code!=202{t.Fatal(r.Code,r.Body.String())}
 if strings.Contains(r.Body.String(),"SECRET-SUBSCRIPTION-KEY"){t.Fatal("secret echoed in POST")}
 select{case <-started: case <-time.After(time.Second):t.Fatal("command not started")}
 second:=importReq(h,"http://127.0.0.1:18081","application/x-yaml","apply",secret)
 if second.Code!=409{t.Fatal("duplicate was accepted",second.Code)}
 if strings.Contains(second.Body.String(),"SECRET-SUBSCRIPTION-KEY"){t.Fatal("secret leaked on conflict")}
 close(release)
 end:=untilCompleted(t,a)
 if end.State!="OK"||end.ExitCode==nil||*end.ExitCode!=0{t.Fatal(end)}
 req:=httptest.NewRequest(http.MethodGet,"http://127.0.0.1:18081/api/config/operation",nil)
 w:=httptest.NewRecorder();h.ServeHTTP(w,req)
 if w.Code!=200||strings.Contains(w.Body.String(),"SECRET-SUBSCRIPTION-KEY"){t.Fatal("status leaks secret",w.Body.String())}
}
func TestImportFailedExitDoesNotClaimRollback(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil);a.importer=[]byte("script")
 a.runImport=func(_ []byte,_ string)(int,error){return 27,errors.New("bad config SECRET-PASSWORD")}
 h:=a.handler()
 r:=importReq(h,"http://127.0.0.1:18081","application/x-yaml","apply",[]byte("mixed-port: 7890\n"))
 if r.Code!=202{t.Fatal(r.Code,r.Body.String())}
 last:=untilCompleted(t,a)
 if last.State!="FAIL"||last.ErrorCode!="IMPORT_FAILED"||last.ExitCode==nil||*last.ExitCode!=27{t.Fatal(last)}
 if strings.Contains(last.ErrorCode,"SECRET-PASSWORD"){t.Fatal("leaked command error")}
}
func TestImportActualShellArgumentNoTTY(t *testing.T){
 // The shell consumes the embedded script on stdin, with exactly one file argument.
 script:=[]byte("test \"$#\" -eq 1 && test -f \"$1\" && grep -q 'mixed-port: 7890' \"$1\"\n")
 f,err:=os.CreateTemp("/tmp","kas-shell-test-*");if err!=nil{t.Fatal(err)}
 defer os.Remove(f.Name())
 if _,err=io.WriteString(f,"mixed-port: 7890\n");err!=nil{t.Fatal(err)}
 if err=f.Close();err!=nil{t.Fatal(err)}
 exit,err:=importCommand(script,f.Name())
 if err!=nil||exit!=0{t.Fatalf("script failed: %v exit=%d",err,exit)}
}
