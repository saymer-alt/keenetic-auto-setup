package main

import (
 "bytes"
 "net/http"
 "net/http/httptest"
 "testing"
)

func TestGracefulStopBlocksNewConfigAndDoctor(t *testing.T) {
 a:=newApp("127.0.0.1:18081",[]byte("exit 0"))
 a.importer=[]byte("exit 0")
 a.mu.Lock()
 a.shuttingDown=true
 a.mu.Unlock()
 req:=httptest.NewRequest(http.MethodPost,"http://127.0.0.1:18081/api/config/import",
  bytes.NewBufferString("mixed-port: 7890\n"))
 req.Host="127.0.0.1:18081"
 req.Header.Set("Origin","http://127.0.0.1:18081")
 req.Header.Set("Content-Type","application/x-yaml")
 req.Header.Set("X-KAS-Confirm","apply")
 w:=httptest.NewRecorder()
 a.handler().ServeHTTP(w,req)
 if w.Code!=http.StatusConflict{t.Fatalf("import during shutdown: %d %s",w.Code,w.Body)}
 req=httptest.NewRequest(http.MethodPost,"http://127.0.0.1:18081/api/doctor",
  bytes.NewBufferString("{}"))
 req.Host="127.0.0.1:18081"
 req.Header.Set("Origin","http://127.0.0.1:18081")
 req.Header.Set("Content-Type","application/json")
 w=httptest.NewRecorder()
 a.handler().ServeHTTP(w,req)
 if w.Code!=http.StatusTooManyRequests{t.Fatalf("doctor during shutdown: %d %s",w.Code,w.Body)}
}
