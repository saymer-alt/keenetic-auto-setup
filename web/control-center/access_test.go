package main

import (
 "bytes"
 "encoding/json"
 "net/http/httptest"
 "net/netip"
 "os"
 "path/filepath"
 "strings"
 "testing"
)

func accessApp(t *testing.T)*app{
 t.Helper()
 a:=newApp("192.168.107.1:18081",nil)
 a.lan=&homeLAN{address:a.host,clients:netip.MustParsePrefix("192.168.107.0/24")}
 if err:=a.lan.loadAccessPolicy(filepath.Join(t.TempDir(),"home-only"));err!=nil{t.Fatal(err)}
 return a
}
func accessRequest(a *app,client,method,body string)*httptest.ResponseRecorder{
 r:=httptest.NewRequest(method,"http://"+a.host+"/api/access",bytes.NewBufferString(body))
 r.RemoteAddr=client
 r.Header.Set("Origin","http://"+a.host)
 r.Header.Set("Content-Type","application/json")
 r.Header.Set("X-KAS-Confirm","access")
 w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r);return w
}
func TestAccessPolicyPersistenceAndRoutedClients(t *testing.T){
 a:=accessApp(t)
 vpn:="172.16.3.33:57362";home:="192.168.107.10:5000"
 if w:=accessRequest(a,vpn,"GET","");w.Code!=200||!strings.Contains(w.Body.String(),`"home_only":false`){t.Fatal(w.Code,w.Body.String())}
 // Enabling from VPN is an explicit, confirmed operation; the response is
 // returned before subsequent VPN requests become forbidden.
 if w:=accessRequest(a,vpn,"POST",`{"home_only":true}`);w.Code!=200{t.Fatal(w.Code,w.Body.String())}
 st,err:=os.Stat(a.lan.accessPath);if err!=nil||st.Mode().Perm()!=0600{t.Fatal("private flag missing",st,err)}
 reloaded:=&homeLAN{}
 if err:=reloaded.loadAccessPolicy(a.lan.accessPath);err!=nil||!reloaded.homeOnly.Load(){t.Fatal("not retained across restart",err)}
 if w:=accessRequest(a,vpn,"GET","");w.Code!=403{t.Fatal("VPN not restricted",w.Code)}
 // A forged forwarding header cannot bypass the optional source policy.
 r:=httptest.NewRequest("GET","http://"+a.host+"/api/status",nil)
 r.RemoteAddr=vpn;r.Header.Set("X-Forwarded-For","192.168.107.10")
 w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r);if w.Code!=403{t.Fatal("forwarded-header bypass",w.Code)}
 if w:=accessRequest(a,home,"POST",`{"home_only":false}`);w.Code!=200{t.Fatal(w.Code,w.Body.String())}
 if _,err:=os.Stat(a.lan.accessPath);!os.IsNotExist(err){t.Fatal("flag not removed",err)}
 if err:=reloaded.loadAccessPolicy(a.lan.accessPath);err!=nil||reloaded.homeOnly.Load(){t.Fatal("off not retained",err)}
 if w:=accessRequest(a,vpn,"GET","");w.Code!=200{t.Fatal("VPN not restored",w.Code)}
}
func TestAccessPolicyRejectsUnconfirmedAndMalformedWrites(t *testing.T){
 for _,body:=range []string{`{}`,`{"home_only":null}`,`{"home_only":"yes"}`,`{"home_only":true,"extra":1}`,`{"home_only":true}{}`,strings.Repeat("x",200)}{
  a:=accessApp(t);w:=accessRequest(a,"192.168.107.10:1","POST",body)
  if w.Code!=400||a.lan.homeOnly.Load(){t.Fatalf("%q: %d %s",body,w.Code,w.Body.String())}
 }
 for _,kind:=range []string{"origin","confirm","fetch-site","content-type","host"}{
  a:=accessApp(t)
  r:=httptest.NewRequest("POST","http://"+a.host+"/api/access",strings.NewReader(`{"home_only":true}`))
  r.RemoteAddr="192.168.107.10:1"
  r.Header.Set("Origin","http://"+a.host);r.Header.Set("Content-Type","application/json");r.Header.Set("X-KAS-Confirm","access")
  switch kind{case "origin":r.Header.Set("Origin","https://evil.example");case "confirm":r.Header.Del("X-KAS-Confirm");case "fetch-site":r.Header.Set("Sec-Fetch-Site","cross-site");case "content-type":r.Header.Set("Content-Type","text/plain");case "host":r.Host="evil.example"}
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
  if w.Code!=403||a.lan.homeOnly.Load(){t.Fatal(kind,w.Code,w.Body.String())}
 }
}
func TestAccessPolicyBusyAndStorageFailurePreserveMode(t *testing.T){
 a:=accessApp(t);a.importRunning=true
 if w:=accessRequest(a,"192.168.107.10:1","POST",`{"home_only":true}`);w.Code!=409{t.Fatal(w.Code)}
 a.importRunning=false;a.lan.accessPath=filepath.Join(t.TempDir(),"missing","flag")
 w:=accessRequest(a,"192.168.107.10:1","POST",`{"home_only":true}`)
 if w.Code!=503||a.lan.homeOnly.Load(){t.Fatal(w.Code,w.Body.String())}
 var data map[string]any
 if json.Unmarshal(w.Body.Bytes(),&data)!=nil||strings.Contains(w.Body.String(),a.lan.accessPath){t.Fatal("path leaked",w.Body.String())}
}
func TestAccessPolicyUnsafeFileFailsClosed(t *testing.T){
 path:=filepath.Join(t.TempDir(),"flag")
 if err:=os.WriteFile(path,[]byte("1\n"),0644);err!=nil{t.Fatal(err)}
 if err:=(&homeLAN{}).loadAccessPolicy(path);err==nil{t.Fatal("accepted public flag")}
 if err:=os.Chmod(path,0600);err!=nil{t.Fatal(err)}
 link:=path+"-link";if err:=os.Symlink(path,link);err!=nil{t.Fatal(err)}
 if err:=(&homeLAN{}).loadAccessPolicy(link);err==nil{t.Fatal("accepted symlink")}
 if err:=os.WriteFile(path,[]byte("unexpected"),0600);err!=nil{t.Fatal(err)}
 if err:=(&homeLAN{}).loadAccessPolicy(path);err==nil{t.Fatal("accepted invalid flag")}
}
