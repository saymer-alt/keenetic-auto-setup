package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixtureMetricsRoots(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	sys := filepath.Join(root,"sys")
	proc := filepath.Join(root,"proc")
	if err := os.MkdirAll(filepath.Join(sys,"class/thermal/thermal_zone0"),0700);err!=nil {t.Fatal(err)}
	if err := os.MkdirAll(proc,0700);err!=nil{t.Fatal(err)}
	for name,data := range map[string]string{
		"sys/class/thermal/thermal_zone0/type": "cpu-thermal\n",
		"sys/class/thermal/thermal_zone0/temp": "42500\n",
		"proc/loadavg": "0.25 0.50 0.75 1/100 123\n",
		"proc/uptime": "36000.22 20000.00\n",
		"proc/meminfo": "MemTotal: 524288 kB\nMemAvailable: 262144 kB\nSwapTotal: 262144 kB\nSwapFree: 131072 kB\n",
	} {
		if err:=os.WriteFile(filepath.Join(root,name),[]byte(data),0600);err!=nil{t.Fatal(err)}
	}
	return sys,proc
}

func TestMetricsExistingCollectorWithFixtures(t *testing.T){
	script,err:=assets.ReadFile("scripts/kas-sys-metrics.sh")
	if err!=nil{t.Fatal(err)}
	sys,proc:=fixtureMetricsRoots(t)
	m,err:=runMetricsCollector(context.Background(),script,sys,proc)
	if err!=nil{t.Fatal(err)}
	if m.Schema!="router-metrics/v1"||m.Temperature.Status!="PASS"||m.Temperature.Celsius!="42.5"||
		m.Load.OneMin!="0.25"||m.Uptime.Seconds!="36000"||m.Memory.Total!="524288"||
		m.Swap.Free!="131072"{
		t.Fatalf("unexpected metrics %+v",m)
	}
	if _,err:=os.Stat(filepath.Join(sys,"class/thermal/thermal_zone0/type"));err!=nil{
		t.Fatal("collector modified fixture",err)
	}
	// No identifiable CPU/SoC sensor must stay UNKNOWN, never report a
	// plausible but unrelated board temperature.
	if err:=os.WriteFile(filepath.Join(sys,"class/thermal/thermal_zone0/type"),[]byte("board\n"),0600);err!=nil{t.Fatal(err)}
	m,err=runMetricsCollector(context.Background(),script,sys,proc)
	if err!=nil||m.Temperature.Status!="UNKNOWN"||m.Temperature.Celsius!=""{
		t.Fatal("invented CPU temperature",m,err)
	}
}

func TestMetricsContractRejectsInvalidData(t *testing.T){
	for _,payload:=range []string{
		`{"schema":"wrong","tool":"kas-sys-metrics.sh","tool_version":"0.1.0"}`,
		`{"schema":"router-metrics/v1","tool":"kas-sys-metrics.sh","tool_version":"0.1.0","temperature":{"status":"PASS","celsius":"999.9"}}`,
		`{"schema":"router-metrics/v1","tool":"kas-sys-metrics.sh","tool_version":"0.1.0","temperature":{"status":"PASS","celsius":"<script>"}}`,
	}{
		var got systemMetrics
		_ = json.Unmarshal([]byte(payload),&got)
		if validateMetrics(&got){t.Fatal("accepted invalid metrics",payload)}
	}
}

func TestMetricsEndpointExplicitAndOriginChecked(t *testing.T){
	a:=newApp("127.0.0.1:18080",nil)
	// This fixture tests HTTP gates without assuming a real router sysfs.
	a.metrics=[]byte("exit 2\n")
	request:=func(method,host,origin,confirm string)int{
		r:=httptest.NewRequest(method,"http://"+host+"/api/metrics",strings.NewReader("{}"))
		r.Header.Set("Content-Type","application/json")
		r.Header.Set("Origin",origin)
		r.Header.Set("X-KAS-Confirm",confirm)
		w:=httptest.NewRecorder()
		a.handler().ServeHTTP(w,r)
		return w.Code
	}
	if code:=request("GET",a.host,"http://"+a.host,"metrics");code!=405{t.Fatal(code)}
	if code:=request("POST",a.host,"http://evil.example","metrics");code!=403{t.Fatal(code)}
	if code:=request("POST",a.host,"http://"+a.host,"");code!=403{t.Fatal(code)}
	if code:=request("POST",a.host,"http://"+a.host,"metrics");code!=503{t.Fatal(code)}
}

func TestMetricsNoPassiveExecution(t *testing.T){
	a:=newApp("127.0.0.1:18080",nil)
	a.metrics=[]byte("exit 2\n")
	for _,endpoint:=range []string{"/","/api/status","/api/components"}{
		r:=httptest.NewRequest("GET","http://"+a.host+endpoint,nil)
		w:=httptest.NewRecorder()
		a.handler().ServeHTTP(w,r)
		if w.Code==503{t.Fatal("metrics executed on page load",endpoint)}
	}
}
