package main

import (
 "bytes"
 "net/http"
 "net/http/httptest"
 "testing"
)

// Integration-only regression: the beta.5 default router listener and
// the beta.5 YAML download must work together with the default KeenDNS
// reverse-proxy topology, without a proxy-origin file or a new login.
func TestBeta5CurrentYAMLAvailableViaLANWANAndKeenDNS(t *testing.T) {
 config := []byte("mixed-port: 7890\nsecret: keep-bytes-exact\n# preserve comments\n")
 a := beta5NetworkApp(t)
 calls := 0
 a.filterConfigReader = func() ([]byte,error) { calls++; return config,nil }

 cases := []struct {
  name,host,remote string
  status int
 }{
  {"home","192.168.88.1:8081","192.168.88.22:41000",http.StatusOK},
  {"trusted work client via router firewall","10.0.6.78:8081","10.0.6.42:41000",http.StatusOK},
  {"loopback reverse proxy rewritten host","127.0.0.1:8081","127.0.0.1:41414",http.StatusOK},
  {"KeenDNS preserves public host","kas.lab.keenetic.pro","127.0.0.1:41415",http.StatusOK},
  {"forged remote domain","kas.lab.keenetic.pro","10.0.6.42:41000",http.StatusForbidden},
  {"wrong direct port","10.0.6.78:9090","10.0.6.42:41000",http.StatusForbidden},
 }
 for _,tc:=range cases {
  t.Run(tc.name,func(t *testing.T){
   r:=httptest.NewRequest(http.MethodGet,"http://192.168.88.1:8081/api/config/download",nil)
   r.Host=tc.host
   r.RemoteAddr=tc.remote
   w:=httptest.NewRecorder()
   a.handler().ServeHTTP(w,r)
   if w.Code!=tc.status {t.Fatalf("status=%d want=%d, body=%s",w.Code,tc.status,w.Body.String())}
   if tc.status==http.StatusOK {
    if !bytes.Equal(w.Body.Bytes(),config){t.Fatal("download bytes changed")}
    if w.Header().Get("Cache-Control")!="no-store"{t.Fatal("download cache must be disabled")}
    if w.Header().Get("Content-Disposition")!=`attachment; filename="config.yaml"`{t.Fatal("missing filename")}
   }
  })
 }
 if calls!=4 {t.Fatalf("reader used %d times: must only run for authorized requests",calls)}
}

func TestBeta5HomeOnlyRestrictsYAMLButAllowsRouterProxy(t *testing.T) {
 a:=beta5NetworkApp(t)
 a.lan.homeOnly.Store(true)
 data:=[]byte("mixed-port: 7890\n")
 a.filterConfigReader=func() ([]byte,error) {return data,nil}
 for _,tc:=range []struct {host,remote string; want int}{
  {"192.168.88.1:8081","192.168.88.20:11111",200},
  {"10.0.6.78:8081","10.0.6.42:11111",403},
  {"kas.lab.keenetic.pro","127.0.0.1:11111",200},
 }{
  r:=httptest.NewRequest(http.MethodGet,"http://192.168.88.1:8081/api/config/download",nil)
  r.Host=tc.host;r.RemoteAddr=tc.remote
  w:=httptest.NewRecorder();a.handler().ServeHTTP(w,r)
  if w.Code!=tc.want{t.Fatalf("host=%s remote=%s status=%d want=%d",tc.host,tc.remote,w.Code,tc.want)}
 }
}
