package main

import (
 "bytes"
 "crypto/sha256"
 "encoding/base64"
 "net/http"
 "net/http/httptest"
 "net/netip"
 "os"
 "path/filepath"
 "testing"
)

func TestHomeAddressSelectionGuards(t *testing.T){
 // Never mistake the loopback adapter, wildcard, WAN or absent bridge for Home.
 for _,bad:=range []string{"lo","br1","eth0","ppp0",""}{
  if _,_,err:=homeIPv4(bad);err==nil{t.Errorf("accepted interface %q",bad)}
 }
 if _,err:=newHomeLAN("0.0.0.0:18081","br1","");err==nil{t.Fatal("allowed guest bridge as Home")}
}

func TestHomeLANNoPasswordByDefaultAndIPAllowlist(t *testing.T){
 a:=newApp("192.168.1.1:18081",nil)
 a.lan=&homeLAN{address:a.host,clients:netip.MustParsePrefix("192.168.1.0/24")}
 handler:=a.handler()
 check:=func(ip,host string,want int){
  req:=httptest.NewRequest(http.MethodGet,"http://192.168.1.1:18081/api/status",nil)
  req.RemoteAddr=ip
  req.Host=host
  res:=httptest.NewRecorder()
  handler.ServeHTTP(res,req)
  if res.Code!=want{t.Errorf("%s -> %d, want %d",ip,res.Code,want)}
 }
 check("192.168.1.50:52000",a.host,200)
 check("10.1.30.50:52000",a.host,403)
 check("172.16.0.50:52000",a.host,403)
 check("203.0.113.50:52000",a.host,403)
 check("192.168.1.50:52000","evil.example",403)
}

func TestHomeLANOptionalPasswordAndOrigin(t *testing.T){
 secret:="a very long user set passphrase"
 a:=newApp("192.168.1.1:18081",nil)
 a.lan=&homeLAN{address:a.host,clients:netip.MustParsePrefix("192.168.1.0/24"),
  passwordEnabled:true,passwordDigest:sha256.Sum256([]byte(secret))}
 a.importer=[]byte("exit 0")
 a.runImport=func([]byte,string)(int,error){return 0,nil}
 request:=func(origin,user,password string)*httptest.ResponseRecorder{
  req:=httptest.NewRequest(http.MethodPost,"http://192.168.1.1:18081/api/config/import",
    bytes.NewBufferString("mixed-port: 7890\n"))
  req.RemoteAddr="192.168.1.44:1111"
  req.Host=a.host
  req.Header.Set("Origin",origin)
  req.Header.Set("Content-Type","application/x-yaml")
  req.Header.Set("X-KAS-Confirm","apply")
  if user!="" {req.Header.Set("Authorization","Basic "+base64.StdEncoding.EncodeToString([]byte(user+":"+password)))}
  res:=httptest.NewRecorder();a.handler().ServeHTTP(res,req);return res
 }
 if r:=request(a.origin(),"","");r.Code!=401{t.Fatal("no password",r.Code)}
 if r:=request(a.origin(),"kas","bad");r.Code!=401{t.Fatal("wrong password",r.Code)}
 if r:=request("https://evil.example","kas",secret);r.Code!=403{t.Fatal("cross origin",r.Code)}
 if r:=request(a.origin(),"kas",secret);r.Code!=202{t.Fatal("authorized upload",r.Code,r.Body.String())}
}

func TestProxyOriginValidation(t *testing.T){
 for _,good:=range []string{"https://kas.example.keenetic.pro","https://kas.example.keenetic.pro:8443"} {
  if _,err:=validateProxyOrigin(good);err!=nil{t.Errorf("valid proxy origin %s: %v",good,err)}
 }
 for _,bad:=range []string{"http://example.com","https://user:password@example.com","https://example.com/path","https://example.com?x=1","https://example.com/#fragment","https://example.com."}{
  if _,err:=validateProxyOrigin(bad);err==nil{t.Errorf("bad proxy origin accepted: %s",bad)}
 }
}

func TestProxyHostAndHTTPSOriginPairing(t *testing.T){
 a:=newApp("192.168.1.1:18081",nil)
 a.lan=&homeLAN{clients:netip.MustParsePrefix("192.168.1.0/24")}
 a.proxyOrigin="https://kas.example.keenetic.pro"
 a.proxyHost="kas.example.keenetic.pro"
 a.importer=[]byte("exit 0")
 a.runImport=func([]byte,string)(int,error){return 0,nil}
 req:=func(host,origin,client string)int{
  r:=httptest.NewRequest(http.MethodPost,"http://192.168.1.1:18081/api/config/import",
    bytes.NewBufferString("mixed-port: 7890\n"))
  r.Host=host;r.RemoteAddr=client
  r.Header.Set("Origin",origin)
  r.Header.Set("Content-Type","application/x-yaml")
  r.Header.Set("X-KAS-Confirm","apply")
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
  return w.Code
 }
 if code:=req(a.proxyHost,"http://kas.example.keenetic.pro","127.0.0.1:1000");code!=403{t.Fatalf("proxy HTTP origin accepted: %d",code)}
 if code:=req(a.proxyHost,a.proxyOrigin,"127.0.0.1:1000");code!=202{t.Fatalf("trusted HTTPS proxy rejected: %d",code)}
 if code:=req(a.host,a.proxyOrigin,"192.168.1.20:1100");code!=403{t.Fatalf("wrong host/origin combination: %d",code)}
 if code:=req("evil.example",a.proxyOrigin,"127.0.0.1:1000");code!=403{t.Fatalf("untrusted Host accepted: %d",code)}
 if code:=req(a.host,"http://192.168.1.1:18081","127.0.0.1:1000");code!=403{t.Fatalf("loopback bypassed direct origin guard: %d",code)}
}

func TestPasswordFilePolicy(t *testing.T){
 dir:=t.TempDir()
 p:=filepath.Join(dir,"pass")
 good:="valid-long-password"
 if err:=os.WriteFile(p,[]byte(good+"\n"),0600);err!=nil{t.Fatal(err)}
 policy:=&homeLAN{}
 if err:=policy.loadOptionalPassword("");err!=nil||policy.passwordEnabled{t.Fatal("password must be off by default")}
 if err:=policy.loadOptionalPassword(p);err!=nil{t.Fatal(err)}
 if !policy.passwordEnabled||policy.passwordDigest!=sha256.Sum256([]byte(good)){t.Fatal("password not enabled correctly")}
 if err:=os.Chmod(p,0644);err!=nil{t.Fatal(err)}
 if err:=(&homeLAN{}).loadOptionalPassword(p);err==nil{t.Fatal("accepted world-readable password")}
 if err:=os.Chmod(p,0600);err!=nil{t.Fatal(err)}
 symlink:=filepath.Join(dir,"pass-link")
 if err:=os.Symlink(p,symlink);err!=nil{t.Fatal(err)}
 if err:=(&homeLAN{}).loadOptionalPassword(symlink);err==nil{t.Fatal("accepted symlink to password")}
 if err:=os.WriteFile(p,[]byte("short"),0600);err!=nil{t.Fatal(err)}
 if err:=(&homeLAN{}).loadOptionalPassword(p);err==nil{t.Fatal("accepted too-short password")}
}

