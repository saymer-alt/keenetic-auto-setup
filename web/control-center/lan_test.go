package main

import (
 "bytes"
 "crypto/sha256"
 "crypto/tls"
 "crypto/x509"
 "encoding/base64"
 "encoding/pem"
 "net"
 "net/http"
 "net/http/httptest"
 "net/netip"
 "os"
 "path/filepath"
 "strings"
 "testing"
 "time"
)

func TestTrustedCIDRBoundary(t *testing.T) {
 good:=[]string{"192.168.1.0/24","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"}
 for _,s:=range good{if !privatePrefix(netip.MustParsePrefix(s)){t.Errorf("private CIDR rejected: %s",s)}}
 bad:=[]string{"0.0.0.0/0","10.0.0.0/7","172.15.0.0/16","172.32.0.0/16","192.0.0.0/8","::/0","169.254.0.0/16"}
 for _,s:=range bad{if privatePrefix(netip.MustParsePrefix(s)){t.Errorf("unsafe CIDR accepted: %s",s)}}
 for _,addr:=range []string{"0.0.0.0:18081","127.0.0.1:18081","8.8.8.8:18081","[::]:18081","192.168.1.1:0"}{
  if _,err:=checkLANAddress(addr,"lo","192.168.1.0/24");err==nil{t.Errorf("accepted unsafe listener %s",addr)}
 }
 if _,err:=checkLANAddress("192.168.1.1:18081","lo","0.0.0.0/0");err==nil{t.Fatal("accepted public allowlist")}
 if _,err:=checkLANAddress("192.168.1.1:18081","nonexistent-kas-lan-interface-999","192.168.1.0/24");err==nil{t.Fatal("accepted absent LAN interface")}
}

func TestLANHTTPSAuthAndOrigin(t *testing.T) {
 password:="0123456789012345678901234567890123456789012" // 43 chars for test
 a:=newApp("192.168.1.1:18081",nil)
 a.scheme="https"
 a.lan=&lanPolicy{interfaceName:"br0", clients:netip.MustParsePrefix("192.168.1.0/24"),
   tokenDigest:sha256.Sum256([]byte(password))}
 a.importer=[]byte("exit 0")
 a.runImport=func(_ []byte,_ string)(int,error){return 0,nil}
 request:=func(method,path,client,origin,auth string) *httptest.ResponseRecorder {
  req:=httptest.NewRequest(method,"https://192.168.1.1:18081"+path,
   bytes.NewBufferString("mixed-port: 7890\n"))
  req.Host="192.168.1.1:18081"
  req.RemoteAddr=client
  req.TLS=&tls.ConnectionState{}
  if auth!=""{req.Header.Set("Authorization","Basic "+base64.StdEncoding.EncodeToString([]byte(auth)))}
  req.Header.Set("Origin",origin)
  req.Header.Set("Content-Type","application/x-yaml")
  req.Header.Set("X-KAS-Confirm","apply")
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,req);return w
 }
 auth:="kas:"+password
 if w:=request(http.MethodGet,"/api/status","192.168.1.25:1000","","");w.Code!=401{t.Fatal("no auth",w.Code)}
 if w:=request(http.MethodGet,"/api/status","192.168.1.25:1000","","kas:wrong");w.Code!=401{t.Fatal("wrong auth",w.Code)}
 if w:=request(http.MethodGet,"/api/status","203.0.113.8:1234","",auth);w.Code!=403{t.Fatal("off-LAN accepted",w.Code)}
 if w:=request(http.MethodGet,"/api/status","192.168.1.25:1000","",auth);w.Code!=200{t.Fatal("valid authorized status",w.Code,w.Body)}
 if w:=request(http.MethodPost,"/api/config/import","192.168.1.25:1000","http://192.168.1.1:18081",auth);w.Code!=403{t.Fatal("HTTP-origin accepted",w.Code)}
 if w:=request(http.MethodPost,"/api/config/import","192.168.1.25:1000","https://evil.example",auth);w.Code!=403{t.Fatal("cross-origin accepted",w.Code)}
 if w:=request(http.MethodPost,"/api/config/import","192.168.1.25:1000","https://192.168.1.1:18081",auth);w.Code!=202{t.Fatal("authorized import failed",w.Code,w.Body)}
 // No credential must ever appear in a response body or challenge.
 if w:=request(http.MethodGet,"/api/status","192.168.1.25:1000","","kas:wrong");strings.Contains(w.Body.String(),password){t.Fatal("token disclosed")}
}

func TestLANHTTPNeverAccepted(t *testing.T){
 token:="0123456789012345678901234567890123456789012"
 a:=newApp("192.168.1.1:18081",nil)
 a.scheme="https"
 a.lan=&lanPolicy{clients:netip.MustParsePrefix("192.168.1.0/24"),tokenDigest:sha256.Sum256([]byte(token))}
 req:=httptest.NewRequest(http.MethodGet,"http://192.168.1.1:18081/api/status",nil)
 req.RemoteAddr="192.168.1.2:1234"
 req.SetBasicAuth("kas",token)
 w:=httptest.NewRecorder();a.handler().ServeHTTP(w,req)
 if w.Code!=403{t.Fatal("accepted cleartext",w.Code)}
}

func TestLANCredentialSetupAndPermissions(t *testing.T){
 dir:=filepath.Join(t.TempDir(),"lan-new")
 result,err:=setupLANCredentials("192.168.1.1",dir)
 if err!=nil{t.Fatal(err)}
 if !strings.Contains(result,"Username: kas")||!strings.Contains(result,"Certificate SHA256"){t.Fatal("bootstrap output missing fingerprint")}
 if _,err:=setupLANCredentials("192.168.1.1",dir);err==nil{t.Fatal("overwrote credentials")}
 if _,err:=setupLANCredentials("8.8.8.8",filepath.Join(t.TempDir(),"bad"));err==nil{t.Fatal("permitted public credential IP")}
 for _,name:=range []string{"auth.token","server.key","server.crt"}{
  path:=filepath.Join(dir,name)
  st,err:=os.Lstat(path)
  if err!=nil||st.Mode().Perm()!=0600{t.Fatalf("wrong permissions: %s %v %v",name,err,st.Mode())}
 }
 raw,err:=os.ReadFile(filepath.Join(dir,"server.crt"))
 if err!=nil{t.Fatal(err)}
 block,_:=pem.Decode(raw)
 if block==nil{t.Fatal("missing PEM")}
 crt,err:=x509.ParseCertificate(block.Bytes)
 if err!=nil{t.Fatal(err)}
 if len(crt.IPAddresses)!=1 || crt.IPAddresses[0].String()!="192.168.1.1" {t.Fatal("incorrect SAN",crt.IPAddresses)}
 if time.Until(crt.NotAfter)<300*24*time.Hour {t.Fatal("unexpected short cert")}
 secret:=filepath.Join(dir,"auth.token")
 raw,err=os.ReadFile(secret)
 if err!=nil{t.Fatal(err)}
 token:=strings.TrimSpace(string(raw))
 if len(token)!=43{t.Fatal("not 256-bit token")}
 if _,err:=base64.RawURLEncoding.DecodeString(token);err!=nil{t.Fatal(err)}
 if err:=os.Chmod(secret,0644);err!=nil{t.Fatal(err)}
 if _,err:=checkedPrivateFile(secret,true);err==nil{t.Fatal("accepted public token perms")}
}

func TestLANSecretsRejectSymlink(t *testing.T){
 dir:=t.TempDir()
 source:=filepath.Join(dir,"source")
 link:=filepath.Join(dir,"alias")
 if err:=os.WriteFile(source,[]byte("not a secret"),0600);err!=nil{t.Fatal(err)}
 if err:=os.Symlink(source,link);err!=nil{t.Fatal(err)}
 if _,err:=checkedPrivateFile(link,true);err==nil{t.Fatal("followed token symlink")}
}


func TestLANRealTLS13WithPinnedSelfSignedCertAndAuth(t *testing.T) {
 dir:=filepath.Join(t.TempDir(),"creds")
 if _,err:=setupLANCredentials("192.168.1.1",dir);err!=nil{t.Fatal(err)}
 keypair,err:=tls.LoadX509KeyPair(filepath.Join(dir,"server.crt"),filepath.Join(dir,"server.key"))
 if err!=nil{t.Fatal(err)}
 raw,err:=os.ReadFile(filepath.Join(dir,"server.crt"))
 if err!=nil{t.Fatal(err)}
 roots:=x509.NewCertPool()
 if !roots.AppendCertsFromPEM(raw){t.Fatal("could not trust pinned test cert")}
 tokenBytes,err:=os.ReadFile(filepath.Join(dir,"auth.token"))
 if err!=nil{t.Fatal(err)}
 token:=strings.TrimSpace(string(tokenBytes))
 a:=newApp("192.168.1.1:18081",nil)
 a.scheme="https"
 // The test socket is loopback, but the *production* LAN validation rejects
 // all loopback client prefixes. This is only a TLS protocol test.
 a.lan=&lanPolicy{clients:netip.MustParsePrefix("127.0.0.0/8"),
   tokenDigest:sha256.Sum256([]byte(token))}
 socket,err:=net.Listen("tcp4","127.0.0.1:0")
 if err!=nil{t.Fatal(err)}
 srv:=&http.Server{Handler:a.handler(),TLSConfig:&tls.Config{
  Certificates:[]tls.Certificate{keypair},MinVersion:tls.VersionTLS13}}
 done:=make(chan struct{})
 go func(){_ = srv.ServeTLS(socket,"","");close(done)}()
 defer func(){_ = srv.Close();<-done}()
 cli:=&http.Client{Timeout:3*time.Second,Transport:&http.Transport{
  TLSClientConfig:&tls.Config{RootCAs:roots,ServerName:"192.168.1.1",
   MinVersion:tls.VersionTLS13}}}
 req,err:=http.NewRequest(http.MethodGet,
  "https://"+socket.Addr().String()+"/api/status",nil)
 if err!=nil{t.Fatal(err)}
 req.Host="192.168.1.1:18081"
 resp,err:=cli.Do(req)
 if err!=nil{t.Fatal(err)}
 _ = resp.Body.Close()
 if resp.StatusCode!=401{t.Fatalf("unauthenticated real TLS: %d",resp.StatusCode)}
 req,err=http.NewRequest(http.MethodGet,
  "https://"+socket.Addr().String()+"/api/status",nil)
 if err!=nil{t.Fatal(err)}
 req.Host="192.168.1.1:18081"
 req.SetBasicAuth("kas",token)
 resp,err=cli.Do(req)
 if err!=nil{t.Fatal(err)}
 _ = resp.Body.Close()
 if resp.StatusCode!=200||resp.TLS==nil||resp.TLS.Version!=tls.VersionTLS13{
  t.Fatalf("authorized real TLS 1.3 expected: %d %v",resp.StatusCode,resp.TLS)
 }
}
