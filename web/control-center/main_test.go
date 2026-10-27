package main

import (
 "context"
 "encoding/json"
 "net/http"
 "net/http/httptest"
 "strings"
 "testing"
)

func TestLoopbackOnly(t *testing.T) {
 for _,bad:=range []string{"0.0.0.0:18081","192.168.1.1:18081",":18081","localhost:18081","[::]:18081"} {
  if validateBind(bad)==nil { t.Errorf("accepted %s",bad) }
 }
 for _,good:=range []string{"127.0.0.1:18081","[::1]:18081"}{
  if err:=validateBind(good);err!=nil{t.Error(err)}
 }
}
func TestHostOriginGuardsAndDoctor(t *testing.T){
 a:=newApp("127.0.0.1:18081",[]byte("echo hi"))
 count:=0
 a.runDoctor=func(_ context.Context,_ []byte)(string,int,error){count++;return "token: secret123\nhealthy",0,nil}
 handler:=a.handler()
 request:=func(host,origin,contentType string)*httptest.ResponseRecorder{
  req:=httptest.NewRequest(http.MethodPost,"http://127.0.0.1:18081/api/doctor",strings.NewReader("{}"))
  req.Host=host;req.Header.Set("Origin",origin);req.Header.Set("Content-Type",contentType)
  w:=httptest.NewRecorder();handler.ServeHTTP(w,req);return w
 }
 if request("evil.example","http://127.0.0.1:18081","application/json").Code!=403{t.Fatal("DNS rebinding allowed")}
 if request("127.0.0.1:18081","http://evil.example","application/json").Code!=403{t.Fatal("cross-origin allowed")}
 if request("127.0.0.1:18081","http://127.0.0.1:18081","text/plain").Code!=403{t.Fatal("form CSRF allowed")}
 r:=request("127.0.0.1:18081","http://127.0.0.1:18081","application/json")
 if r.Code!=200{t.Fatal(r.Code,r.Body.String())}
 var data apiResult
 if err:=json.Unmarshal(r.Body.Bytes(),&data);err!=nil{t.Fatal(err)}
 if strings.Contains(data.Details,"secret123"){t.Fatal("secret leaked")}
 if count!=1{t.Fatal("expected exactly one call",count)}
 if request("127.0.0.1:18081","http://127.0.0.1:18081","application/json").Code!=429{t.Fatal("throttle failed")}
}
func TestReadOnlyStatus(t *testing.T){
 a:=newApp("127.0.0.1:18081",nil)
 req:=httptest.NewRequest(http.MethodGet,"http://127.0.0.1:18081/api/status",nil)
 w:=httptest.NewRecorder();a.handler().ServeHTTP(w,req)
 if w.Code!=200{t.Fatal(w.Code)}
 var data apiResult
 if err:=json.Unmarshal(w.Body.Bytes(),&data);err!=nil{t.Fatal(err)}
 if data.State!="UNKNOWN"{t.Fatalf("falsely healthy: %s",data.State)}
}
func TestDoctorExit(t *testing.T){
 out,exit,err:=doctorCommand(context.Background(),[]byte("printf failure; exit 7"))
 if err==nil||exit!=7||out!="failure"{t.Fatal(out,exit,err)}
}
