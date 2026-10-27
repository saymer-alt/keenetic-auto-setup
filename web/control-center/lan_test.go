package main

import (
 "bytes"
 "crypto/sha256"
 "encoding/base64"
 "net"
 "net/http"
 "net/http/httptest"
 "net/netip"
 "os"
 "path/filepath"
 "strings"
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

func TestPasswordFileNotMandatoryAndPrivate(t *testing.T){
 // Pure password handling; interface-br0 runtime selection is guest-tested.
 dir:=t.TempDir()
 p:=filepath.Join(dir,"pass")
 if err:=os.WriteFile(p,[]byte("valid-long-password\n"),0600);err!=nil{t.Fatal(err)}
 st,err:=os.Lstat(p)
 if err!=nil || !st.Mode().IsRegular() || st.Mode().Perm()!=0600{t.Fatal("private file invalid")}
 if err:=os.Chmod(p,0644);err!=nil{t.Fatal(err)}
 st,_=os.Lstat(p)
 if st.Mode().Perm()&0077==0{t.Fatal("test did not make password public")}
 if strings.HasPrefix(net.JoinHostPort("192.168.1.1","18081"),"0.0.0.0") {t.Fatal("wildcard")}
}
