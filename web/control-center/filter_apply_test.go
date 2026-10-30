package main
import(
 "bytes"
 "encoding/json"
 "net/http"
 "net/http/httptest"
 "os"
 "runtime"
 "strings"
 "testing"
 "time"
)
func applyReq(handler http.Handler,origin,ctype,confirm string,body []byte)*httptest.ResponseRecorder{
 r:=httptest.NewRequest(http.MethodPost,"http://127.0.0.1:18081/api/filter/apply",bytes.NewReader(body))
 r.Host="127.0.0.1:18081"
 r.Header.Set("Origin",origin);r.Header.Set("Content-Type",ctype);r.Header.Set("X-KAS-Confirm",confirm)
 w:=httptest.NewRecorder();handler.ServeHTTP(w,r);return w
}
func applyBody(t *testing.T,req filterEditRequest)[]byte{t.Helper();b,err:=json.Marshal(req);if err!=nil{t.Fatal(err)};return b}
func applyFixtureApp(t *testing.T)([]byte,*app){
 t.Helper()
 a:=newApp("127.0.0.1:18081",nil)
 a.providers=&providerNamesExporter{}
 a.importer=[]byte("canonical importer")
 a.filterConfigReader=func()([]byte,error){return []byte(inputFilterFixture),nil}
 return []byte(inputFilterFixture),a
}
func applyLoadedNames(t *testing.T,a *app){
 t.Helper()
 source:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  _,_=w.Write([]byte(`{"providers":{"Provider-One":{"proxies":[{"name":"Node A"},{"name":"Node B"}]},"Provider-Two":{"proxies":[{"name":"Node C"}]}}}`))
 }))
 t.Cleanup(source.Close)
 a.providers=&providerNamesExporter{sources:[]string{source.URL+"/providers/proxies"},client:source.Client()}
}
func untilApplyDone(t *testing.T,a *app)importStatus{
 t.Helper()
 deadline:=time.Now().Add(2*time.Second)
 for time.Now().Before(deadline){
  a.mu.Lock();v:=a.importResult;busy:=a.importRunning;a.mu.Unlock()
  if !busy&&(v.State=="OK"||v.State=="FAIL"){return v}
  time.Sleep(5*time.Millisecond)
 }
 t.Fatal("filter apply operation timed out in test")
 return importStatus{}
}
func TestFilterApplyRejectsGuardsAndInvalidInput(t *testing.T){
 fixture,a:=applyFixtureApp(t)
 h:=a.handler()
 digest:=filterSourceDigest(fixture)
 good:=applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},SourceSHA:digest})
 cases:=[]struct{name string;origin,ctype,confirm string;body []byte;want int}{
  {"cross origin","http://evil.example","application/json","apply",good,403},
  {"wrong confirm","http://127.0.0.1:18081","application/json","preview",good,403},
  {"wrong ctype","http://127.0.0.1:18081","application/x-yaml","apply",good,403},
  {"bad json","http://127.0.0.1:18081","application/json","apply",[]byte("{"),400},
  {"unknown field","http://127.0.0.1:18081","application/json","apply",[]byte(`{"provider":"P","names":[],"clear":false,"source_sha":"`+digest+`","extra":1}`),400},
  {"trailing json","http://127.0.0.1:18081","application/json","apply",[]byte(`{"provider":"P","names":[],"clear":false,"source_sha":"`+digest+`"}{}`),400},
  {"bad sha","http://127.0.0.1:18081","application/json","apply",applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},SourceSHA:"nothex"}),400},
  {"clear with names","http://127.0.0.1:18081","application/json","apply",applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},Clear:true,SourceSHA:digest}),400},
  {"empty name","http://127.0.0.1:18081","application/json","apply",applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{" "},SourceSHA:digest}),400},
 }
 for _,tc:=range cases{
  res:=applyReq(h,tc.origin,tc.ctype,tc.confirm,tc.body)
  if res.Code!=tc.want{t.Fatalf("%s: status %d expected %d body=%s",tc.name,res.Code,tc.want,res.Body.String())}
 }
 if operation(a).State!=""{t.Fatal("rejected apply started an operation")}
 if a.importRunning{t.Fatal("slot leaked on rejected apply")}
}
func TestFilterApplyEditorAndImporterDisabled(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil)
 a.providers=&providerNamesExporter{}
 a.importer=nil
 h:=a.handler()
 if w:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",[]byte(`{}`));w.Code!=503{t.Fatal(w.Code,w.Body.String())}
 a.importer=[]byte("canonical importer")
 a.providers=nil
 if w:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",[]byte(`{}`));w.Code!=404{t.Fatal(w.Code,w.Body.String())}
}
func TestFilterApplyStaleSourceAndBusy(t *testing.T){
 fixture,a:=applyFixtureApp(t)
 h:=a.handler()
 stale:="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
 res:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},SourceSHA:stale}))
 if res.Code!=409||!strings.Contains(res.Body.String(),"CONFIG_CHANGED"){t.Fatal(res.Code,res.Body.String())}
 if a.importRunning{t.Fatal("slot leaked on stale apply")}
 a.mu.Lock();a.importRunning=true;a.mu.Unlock()
 res=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},SourceSHA:filterSourceDigest(fixture)}))
 if res.Code!=409||!strings.Contains(res.Body.String(),"BUSY"){t.Fatal(res.Code,res.Body.String())}
 a.mu.Lock();a.importRunning=false;a.running=true;a.mu.Unlock()
 res=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},SourceSHA:filterSourceDigest(fixture)}))
 if res.Code!=409{t.Fatal("doctor-concurrent apply accepted",res.Code)}
 a.mu.Lock();a.running=false;a.mu.Unlock()
 if operation(a).State!=""{t.Fatal("busy path started an operation")}
}
func TestFilterApplyStagesSnapshotForImporterGate(t *testing.T){
 fixture,a:=applyFixtureApp(t)
 applyLoadedNames(t,a)
 started:=make(chan []string,1);release:=make(chan struct{})
 a.runImport=func(script []byte,path string,extraEnv []string)(int,error){
  if string(script)!="canonical importer"{t.Error("unexpected importer payload")}
  if len(extraEnv)!=1||!strings.HasPrefix(extraEnv[0],"KAS_EXPECTED_SOURCE="){
   t.Error("expected-source gate input missing")
  }else{
   snapshot:=strings.TrimPrefix(extraEnv[0],"KAS_EXPECTED_SOURCE=")
   data,err:=os.ReadFile(snapshot)
   if err!=nil{t.Error(err)}else if string(data)!=string(fixture){
    t.Error("gate snapshot does not hold the approved source bytes")
   }
   if runtime.GOOS=="unix"{
    if st,err:=os.Stat(snapshot);err!=nil||st.Mode().Perm()!=0600{t.Errorf("snapshot perms %v",err)}
    if st,err:=os.Stat(path);err!=nil||st.Mode().Perm()!=0600{t.Errorf("candidate perms %v",err)}
   }
   patched:=string(fixture)
   patched=strings.Replace(patched,"  Provider-One:\n","  Provider-One:\n    exclude-filter: \"^(?:Node A)$\"\n",1)
   body,err:=os.ReadFile(path)
   if err!=nil{t.Error(err)}else if string(body)!=patched{t.Errorf("candidate mismatch:\n%s",body)}
  }
  started<-extraEnv
  <-release
  return 0,nil
 }
 h:=a.handler()
 res:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},SourceSHA:filterSourceDigest(fixture)}))
 if res.Code!=202{t.Fatalf("status %d body=%s",res.Code,res.Body.String())}
 var entry importStatus
 if err:=json.Unmarshal(res.Body.Bytes(),&entry);err!=nil{t.Fatal(err)}
 if entry.State!="RUNNING"||len(entry.ID)!=24{t.Fatal("apply response not a running operation",entry)}
 if strings.Contains(res.Body.String(),"SENSITIVE_NOT_TO_LEAK")||strings.Contains(res.Body.String(),"private.invalid"){
  t.Fatal("apply response leaked config payload")
 }
 select{case <-started:case <-time.After(time.Second):t.Fatal("importer not started")}
 dup:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-Two",Names:[]string{"Node B"},SourceSHA:filterSourceDigest(fixture)}))
 if dup.Code!=409{t.Fatal("concurrent filter apply accepted",dup.Code)}
 close(release)
 end:=untilApplyDone(t,a)
 if end.State!="OK"||end.ExitCode==nil||*end.ExitCode!=0{t.Fatal(end)}
 if !strings.Contains(end.Source,"filter apply"){t.Fatal("operation source unlabeled",end.Source)}
 w:=httptest.NewRequest(http.MethodGet,"http://127.0.0.1:18081/api/config/operation",nil)
 rec:=httptest.NewRecorder();h.ServeHTTP(rec,w)
 if strings.Contains(rec.Body.String(),"SENSITIVE_NOT_TO_LEAK"){t.Fatal("status endpoint leaked config payload")}
 time.Sleep(50*time.Millisecond)
}
func TestFilterApplyFailedExitReportsFailure(t *testing.T){
 fixture,a:=applyFixtureApp(t)
 applyLoadedNames(t,a)
 a.runImport=func(_ []byte,_ string,_ []string)(int,error){return 3,nil}
 h:=a.handler()
 res:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Node A"},SourceSHA:filterSourceDigest(fixture)}))
 if res.Code!=202{t.Fatal(res.Code)}
 end:=untilApplyDone(t,a)
 if end.State!="FAIL"||end.ErrorCode!="FILTER_APPLY_FAILED"||end.ExitCode==nil||*end.ExitCode!=3{t.Fatal(end)}
}
func TestFilterApplyNoChangeSkipsImporter(t *testing.T){
 fixture,a:=applyFixtureApp(t)
 a.runImport=func([]byte,string,[]string)(int,error){t.Error("no-op started the importer");return 0,nil}
 h:=a.handler()
 // Clearing when no filter exists is a no-op for this provider.
 res:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Clear:true,SourceSHA:filterSourceDigest(fixture)}))
 if res.Code!=200||!strings.Contains(res.Body.String(),"NO_CHANGE"){t.Fatal(res.Code,res.Body.String())}
 if !strings.Contains(res.Body.String(),`"applied":false`){t.Fatal("claimed applied",res.Body.String())}
 if a.importRunning{t.Fatal("slot leaked on no-op")}
 if operation(a).State!=""{t.Fatal("no-op recorded an operation")}
}
func TestFilterApplyClearWorksWithoutLoadedNames(t *testing.T){
 // provider-filtered config: Provider-Two has "(?i)russia" to clear, and the
 // Mihomo snapshot provider would never be consulted for a clear request.
 fixture,a:=applyFixtureApp(t)
 unavail:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  t.Error("clear must not depend on loaded provider names")
  w.WriteHeader(http.StatusBadGateway)
 }))
 defer unavail.Close()
 a.providers=&providerNamesExporter{sources:[]string{unavail.URL+"/providers/proxies"},client:unavail.Client()}
 a.runImport=func(script []byte,path string,extraEnv []string)(int,error){
  data,err:=os.ReadFile(path)
  if err!=nil{t.Error(err);return -1,err}
  if strings.Contains(string(data),`exclude-filter: "(?i)russia"`){t.Error("clear did not remove the manual filter line")}
  if !strings.Contains(string(data),"Provider-Two"){t.Error("clear removed the provider")}
  return 0,nil
 }
 h:=a.handler()
 res:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-Two",Clear:true,SourceSHA:filterSourceDigest(fixture)}))
 if res.Code!=202{t.Fatalf("status %d body=%s",res.Code,res.Body.String())}
 end:=untilApplyDone(t,a)
 if end.State!="OK"{t.Fatal(end)}
}
func TestFilterApplyUnloadedNodeRejectedWithoutImport(t *testing.T){
 fixture,a:=applyFixtureApp(t)
 source:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  _,_=w.Write([]byte(`{"providers":{"Provider-One":{"proxies":[{"name":"Node A"}]}}}`))
 }))
 defer source.Close()
 a.providers=&providerNamesExporter{sources:[]string{source.URL+"/providers/proxies"},client:source.Client()}
 a.runImport=func([]byte,string,[]string)(int,error){t.Error("import started for unloaded node");return 0,nil}
 h:=a.handler()
 res:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Names:[]string{"Ghost"},SourceSHA:filterSourceDigest(fixture)}))
 if res.Code!=422||!strings.Contains(res.Body.String(),"NODE_NOT_LOADED"){t.Fatal(res.Code,res.Body.String())}
 if a.importRunning{t.Fatal("slot leaked after unloaded node rejection")}
}
func TestFilterApplyConfigUnavailable(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil)
 a.providers=&providerNamesExporter{}
 a.importer=[]byte("canonical importer")
 a.filterConfigReader=func()([]byte,error){return nil,errFilterUnsupported}
 h:=a.handler()
 res:=applyReq(h,"http://127.0.0.1:18081","application/json","apply",
  applyBody(t,filterEditRequest{Provider:"Provider-One",Clear:true,SourceSHA:filterSourceDigest([]byte("x"))}))
 if res.Code!=503{t.Fatal(res.Code,res.Body.String())}
 if a.importRunning{t.Fatal("slot leaked on unavailable config")}
}
