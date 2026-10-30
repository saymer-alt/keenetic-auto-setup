package main
import(
 "bytes"
 "encoding/json"
 "net/http"
 "net/http/httptest"
 "strings"
 "testing"
)
func TestFilterInspectNeverExposesConfigOrSubscriptions(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil)
 a.providers=&providerNamesExporter{}
 a.filterConfigReader=func()([]byte,error){return []byte(inputFilterFixture),nil}
 r:=httptest.NewRequest("GET","http://127.0.0.1:18081/api/filter/providers",nil)
 w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
 if w.Code!=200{t.Fatal(w.Code,w.Body.String())}
 s:=w.Body.String()
 if !strings.Contains(s,"Provider-One")||!strings.Contains(s,"source_sha"){t.Fatal("missing safe metadata")}
 for _,v:=range []string{"SENSITIVE_NOT_TO_LEAK","https://private.invalid","SECRET"}{
  if strings.Contains(s,v){t.Fatalf("private config leaked: %s",v)}
 }
 if w.Header().Get("Cache-Control")!="no-store"{t.Fatal("cacheable")}
}
func TestFilterPreviewSameOriginAndLoadedNodeOnly(t *testing.T){
 source:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  if r.URL.Path!="/providers/proxies"||r.Method!="GET"{t.Error("unexpected upstream")}
  _,_=w.Write([]byte(`{"providers":{"Provider-One":{"proxies":[{"name":"🇷🇺 Moscow"},{"name":"DE+Berlin"}]}}}`))
 }))
 defer source.Close()
 a:=newApp("127.0.0.1:18081",nil)
 a.providers=&providerNamesExporter{sources:[]string{source.URL+"/providers/proxies"},client:source.Client()}
 a.filterConfigReader=func()([]byte,error){return []byte(inputFilterFixture),nil}
 digest:=filterSourceDigest([]byte(inputFilterFixture))
 invoke:=func(origin string,names []string,sha string)*httptest.ResponseRecorder{
  body,_:=json.Marshal(filterEditRequest{Provider:"Provider-One",Names:names,SourceSHA:sha})
  r:=httptest.NewRequest("POST","http://127.0.0.1:18081/api/filter/preview",bytes.NewReader(body))
  r.Header.Set("Origin",origin);r.Header.Set("Content-Type","application/json");r.Header.Set("X-KAS-Confirm","preview")
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r);return w
 }
 if w:=invoke("http://evil.example",[]string{"DE+Berlin"},digest);w.Code!=403{t.Fatal(w.Code)}
 if w:=invoke("http://127.0.0.1:18081",[]string{"Unknown"},digest);w.Code!=422{t.Fatal(w.Code)}
 if w:=invoke("http://127.0.0.1:18081",[]string{"DE+Berlin"},"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");w.Code!=409{t.Fatal(w.Code)}
 w:=invoke("http://127.0.0.1:18081",[]string{"DE+Berlin"},digest)
 if w.Code!=200{t.Fatal(w.Code,w.Body.String())}
 var result filterPreviewResponse
 if err:=json.Unmarshal(w.Body.Bytes(),&result);err!=nil{t.Fatal(err)}
 if result.Applied||result.CandidateSHA==result.SourceSHA||result.Proposed==""{t.Fatal("preview not safe",result)}
 if strings.Contains(w.Body.String(),"private.invalid"){t.Fatal("YAML leaked")}
}
func TestFilterInspectDisabledAndPreviewNoWrite(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil)
 a.filterConfigReader=func()([]byte,error){t.Fatal("should not read config");return nil,nil}
 for _,target:=range []string{"/api/filter/providers","/api/filter/preview"}{
  method:="GET";if strings.HasSuffix(target,"preview"){method="POST"}
  r:=httptest.NewRequest(method,"http://127.0.0.1:18081"+target,nil)
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
  if w.Code!=404{t.Fatalf("%s status %d",target,w.Code)}
 }
}
