package main

import (
 "bytes"
 "errors"
 "net/http"
 "net/http/httptest"
 "net/netip"
 "strings"
 "testing"
)

func TestDownloadCurrentYAMLReturnsExactFileNoStore(t *testing.T) {
 a := newApp("192.168.88.1:8081", nil)
 a.lan = &homeLAN{address:a.host, clients:netip.MustParsePrefix("192.168.88.0/24")}
 data := []byte("mixed-port: 7890\nproxy-providers:\n  Sample:\n    url: https://private.example/secret\n")
 a.filterConfigReader = func() ([]byte,error) { return data,nil }
 r := httptest.NewRequest(http.MethodGet,"http://192.168.88.1:8081/api/config/download",nil)
 r.RemoteAddr = "192.168.88.33:55555"
 w := httptest.NewRecorder()
 a.handler().ServeHTTP(w,r)
 if w.Code != http.StatusOK { t.Fatalf("download status = %d: %s",w.Code,w.Body.String()) }
 if !bytes.Equal(data,w.Body.Bytes()) { t.Fatal("download bytes differ from current config") }
 if got := w.Header().Get("Content-Disposition");got != `attachment; filename="config.yaml"` { t.Fatalf("disposition = %q",got) }
 if got := w.Header().Get("Cache-Control");got != "no-store" { t.Fatalf("Cache-Control = %q",got) }
 if got := w.Header().Get("Content-Type");!strings.HasPrefix(got,"application/x-yaml") { t.Fatalf("type = %q",got) }
 if got := w.Header().Get("X-Content-Type-Options");got != "nosniff" { t.Fatalf("nosniff = %q",got) }
}

func TestDownloadCurrentYAMLMissingOrWrongMethod(t *testing.T) {
 a := newApp("192.168.88.1:8081", nil)
 a.lan = &homeLAN{address:a.host, clients:netip.MustParsePrefix("192.168.88.0/24")}
 a.filterConfigReader = func() ([]byte,error) { return nil,errors.New("private path and token") }
 get := httptest.NewRequest(http.MethodGet,"http://"+a.host+"/api/config/download",nil)
 get.RemoteAddr="192.168.88.10:12345"
 w := httptest.NewRecorder()
 a.handler().ServeHTTP(w,get)
 if w.Code!=http.StatusServiceUnavailable { t.Fatalf("get status %d",w.Code) }
 if !strings.Contains(w.Body.String(),"CONFIG_UNAVAILABLE") || strings.Contains(w.Body.String(),"private path") {
  t.Fatalf("unexpected error body %q",w.Body.String())
 }
 post:=httptest.NewRequest(http.MethodPost,"http://"+a.host+"/api/config/download",nil)
 post.RemoteAddr="192.168.88.10:12345"
 w=httptest.NewRecorder()
 a.handler().ServeHTTP(w,post)
 if w.Code!=http.StatusMethodNotAllowed { t.Fatalf("post status %d",w.Code) }
}
