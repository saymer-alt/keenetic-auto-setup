package main

import (
 "bytes"
 "net/http"
 "net/http/httptest"
 "net/netip"
 "path/filepath"
 "testing"
)

func beta5NetworkApp(t *testing.T) *app {
 t.Helper()
 a:=newApp("0.0.0.0:8081",nil)
 a.lan=&homeLAN{address:a.host,homeIP:netip.MustParseAddr("192.168.88.1"),clients:netip.MustParsePrefix("192.168.88.0/24")}
 if err:=a.lan.loadAccessPolicy(filepath.Join(t.TempDir(),"home-only"));err!=nil{t.Fatal(err)}
 return a
}

func TestBeta5DefaultRouterInterfacesAndKeenDNS(t *testing.T) {
 a:=beta5NetworkApp(t)
 cases:=[]struct{name,host,client string;want int}{
  {"home","192.168.88.1:8081","192.168.88.20:35000",200},
  {"work wan permitted by router","10.0.6.78:8081","10.0.6.42:50000",200},
  {"loopback","127.0.0.1:8081","127.0.0.1:45555",200},
  {"keendns via loopback","kas.sotsenergo.crazedns.ru","127.0.0.1:55555",200},
  {"keendns via Home proxy","kas.sotsenergo.crazedns.ru","192.168.88.1:55555",200},
  {"spoofed domain from WAN","evil.example","10.0.6.42:50000",403},
  {"wrong port","10.0.6.78:9090","10.0.6.42:50000",403},
 }
 for _,tc:=range cases {
  t.Run(tc.name,func(t *testing.T){
   r:=httptest.NewRequest(http.MethodGet,"http://"+a.host+"/api/status",nil)
   r.Host=tc.host;r.RemoteAddr=tc.client
   w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
   if w.Code!=tc.want{t.Fatalf("Host=%s peer=%s code=%d, want=%d",tc.host,tc.client,w.Code,tc.want)}
  })
 }
}

func TestBeta5KeenDNSPOSTAndOriginGuard(t *testing.T) {
 a:=beta5NetworkApp(t)
 test:=func(host,client,origin,fetchSite string,want int){
  t.Helper()
  r:=httptest.NewRequest(http.MethodPost,"http://"+a.host+"/api/access",bytes.NewBufferString(`{"home_only":false}`))
  r.Host=host;r.RemoteAddr=client
  if origin!=""{r.Header.Set("Origin",origin)}
  if fetchSite!=""{r.Header.Set("Sec-Fetch-Site",fetchSite)}
  r.Header.Set("Content-Type","application/json")
  r.Header.Set("X-KAS-Confirm","access")
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
  if w.Code!=want{t.Fatalf("Host=%q peer=%q Origin=%q Fetch=%q code=%d want=%d body=%s",host,client,origin,fetchSite,w.Code,want,w.Body.String())}
 }
 test("10.0.6.78:8081","10.0.6.42:11111","http://10.0.6.78:8081","same-origin",200)
 test("192.168.88.1:8081","192.168.88.22:11111","http://192.168.88.1:8081","same-origin",200)
 test("kas.sotsenergo.crazedns.ru","127.0.0.1:11111","https://kas.sotsenergo.crazedns.ru","same-origin",200)
 test("127.0.0.1:8081","127.0.0.1:11111","https://kas.sotsenergo.crazedns.ru","same-origin",200)
 test("127.0.0.1:8081","127.0.0.1:11111","","",200) // KeenDNS may strip Origin
 test("127.0.0.1:8081","127.0.0.1:11111","https://attacker.example","cross-site",403)
 test("127.0.0.1:8081","10.0.6.42:11111","https://kas.sotsenergo.crazedns.ru","same-origin",403)
 test("evil.example","127.0.0.1:11111","https://kas.sotsenergo.crazedns.ru","same-origin",403)
 test("10.0.6.78:8081","10.0.6.42:11111","https://kas.sotsenergo.crazedns.ru","same-origin",403)
}

func TestBeta5HomeOnlyStillRestrictsRoutedClients(t *testing.T){
 a:=beta5NetworkApp(t)
 a.lan.homeOnly.Store(true)
 for _,tc:=range []struct{peer string;want int}{
  {"192.168.88.33:33333",200},
  {"10.0.6.42:33333",403},
  {"172.16.3.42:33333",403},
 }{
  r:=httptest.NewRequest(http.MethodGet,"http://10.0.6.78:8081/api/status",nil)
  r.RemoteAddr=tc.peer
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
  if w.Code!=tc.want{t.Fatalf("peer=%s got=%d want=%d",tc.peer,w.Code,tc.want)}
 }
}

func TestBeta5StartupAddressShowsReachableHomeIP(t *testing.T){
 p:=&homeLAN{address:"0.0.0.0:8081",homeIP:netip.MustParseAddr("192.168.88.1")}
 if got:=p.describe();len(got)<len("Home-address HTTP 192.168.88.1:8081")||got[:len("Home-address HTTP 192.168.88.1:8081")]!="Home-address HTTP 192.168.88.1:8081" {
  t.Fatalf("unexpected startup address %q",got)
 }
}
