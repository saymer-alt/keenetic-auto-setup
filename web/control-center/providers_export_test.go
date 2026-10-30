package main

import(
 "encoding/json"
 "net/http"
 "net/http/httptest"
 "os"
 "path/filepath"
 "strings"
 "testing"
)

const syntheticNamesJSON = `{"providers":{"Provider A":{"vehicleType":"HTTP","proxies":[{"name":"🇷🇺 Узел","uuid":"SECRET_UUID","server":"private.host","password":"SECRET_PASS","history":[{"delay":42}]},{"name":"EU node","port":443}]},"Empty":{"vehicleType":"HTTP","proxies":[]}},"danger":"secret"}`

func TestProviderExportSanitizerUsesGeneratorShapeAndNoSecrets(t *testing.T){
 raw,err:=sanitizeProviderNames([]byte(syntheticNamesJSON))
 if err!=nil{t.Fatal(err)}
 for _,secret:=range []string{"SECRET_UUID","SECRET_PASS","private.host",`"port"`,`"delay"`,`"history"`}{
  if strings.Contains(string(raw),secret){t.Fatalf("secret field leaked: %s",secret)}
 }
 var doc struct{Providers map[string]struct{VehicleType string `json:"vehicleType"`;Proxies []struct{Name string `json:"name"`} `json:"proxies"`} `json:"providers"`}
 if err:=json.Unmarshal(raw,&doc);err!=nil{t.Fatal(err)}
 if len(doc.Providers)!=2||doc.Providers["Provider A"].VehicleType!="HTTP"||len(doc.Providers["Provider A"].Proxies)!=2||doc.Providers["Provider A"].Proxies[0].Name!="🇷🇺 Узел"{
  t.Fatal("generator importer compatible names structure not preserved")
 }
 if len(doc.Providers["Empty"].Proxies)!=0{t.Fatal("empty provider lost")}
}

func TestProviderExportRejectsBadResponses(t *testing.T){
 for _,s:=range []string{"",`{}`,`{"proxies":{}}`,`{"providers":[]}`,`{"providers":{`} {
  if _,err:=sanitizeProviderNames([]byte(s));err==nil{t.Fatalf("accepted invalid upstream JSON: %s",s)}
 }
}


func TestProviderExportDisabledAndReadOnly(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil)
 request:=func(method string)*httptest.ResponseRecorder{
  r:=httptest.NewRequest(method,"http://127.0.0.1:18081/api/providers/names",nil)
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r);return w
 }
 if w:=request(http.MethodGet);w.Code!=404{t.Fatal("disabled export exposed",w.Code)}
 if w:=request(http.MethodPost);w.Code!=405{t.Fatal("non-GET accepted",w.Code)}
}

func TestProviderExportFetchesLocalReadOnlyAndKeepsTokenServerSide(t *testing.T){
 count:=0
 source:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  count++
  if r.Method!="GET"||r.URL.Path!="/providers/proxies"{t.Error("non read-only controller operation")}
  if r.Header.Get("Authorization")!="Bearer local-secret"{w.WriteHeader(http.StatusUnauthorized);return}
  _,_=w.Write([]byte(syntheticNamesJSON))
 }))
 defer source.Close()
 a:=newApp("127.0.0.1:18081",nil)
 a.providers=&providerNamesExporter{sources:[]string{source.URL+"/providers/proxies"},client:source.Client(),secret:"local-secret"}
 r:=httptest.NewRequest("GET","http://127.0.0.1:18081/api/providers/names",nil)
 w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
 if w.Code!=200{t.Fatal(w.Code,w.Body.String())}
 if count!=1{t.Fatal("expected one explicit local GET")}
 if strings.Contains(w.Body.String(),"local-secret")||strings.Contains(w.Body.String(),"SECRET_PASS"){t.Fatal("secret in response")}
 if w.Header().Get("Cache-Control")!="no-store"{t.Fatal("response cacheable")}
 if !strings.Contains(w.Header().Get("Content-Disposition"),"attachment"){t.Fatal("missing safe attachment")}
}

func TestProviderExportBackendUnauthorizedNoRawLeak(t *testing.T){
 source:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  w.WriteHeader(http.StatusUnauthorized)
  _,_=w.Write([]byte("PRIVATE_CONTROLLER_HOST"))
 }))
 defer source.Close()
 a:=newApp("127.0.0.1:18081",nil)
 a.providers=&providerNamesExporter{sources:[]string{source.URL},client:source.Client()}
 req:=httptest.NewRequest("GET","http://127.0.0.1:18081/api/providers/names",nil)
 w:=httptest.NewRecorder();a.handler().ServeHTTP(w,req)
 if w.Code!=502||!strings.Contains(w.Body.String(),"MIHOMO_AUTH_REQUIRED")||strings.Contains(w.Body.String(),"PRIVATE_CONTROLLER_HOST"){t.Fatal("leaked raw upstream",w.Code,w.Body.String())}
}

func TestProviderExportTargetsLocalHostOnly(t *testing.T){
 p,err:=newProviderNamesExporter("192.168.1.1:18081","")
 if err!=nil||len(p.sources)!=2||p.sources[0]!="http://127.0.0.1:9090/providers/proxies"||p.sources[1]!="http://192.168.1.1:9090/providers/proxies"{t.Fatalf("%v %#v",err,p)}
 if _,err:=newProviderNamesExporter("example.com:18081","");err==nil{t.Fatal("nonlocal target permitted")}
}

func TestProviderSecretMustBePrivateRegularFile(t *testing.T){
 dir:=t.TempDir()
 path:=filepath.Join(dir,"key")
 if err:=os.WriteFile(path,[]byte("private-test-secret\n"),0600);err!=nil{t.Fatal(err)}
 p,err:=newProviderNamesExporter("127.0.0.1:18081",path)
 if err!=nil||p.secret!="private-test-secret"{t.Fatal(err)}
 if err:=os.Chmod(path,0644);err!=nil{t.Fatal(err)}
 if _,err:=newProviderNamesExporter("127.0.0.1:18081",path);err==nil{t.Fatal("world-readable secret accepted")}
 if err:=os.Chmod(path,0600);err!=nil{t.Fatal(err)}
 link:=filepath.Join(dir,"link")
 if err:=os.Symlink(path,link);err!=nil{t.Fatal(err)}
 if _,err:=newProviderNamesExporter("127.0.0.1:18081",link);err==nil{t.Fatal("symlink secret accepted")}
}
