package main

import (
	"context"
	"encoding/json"
	"fmt"
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
		m.Load.OneMin!="0.25"||m.Uptime.Seconds!="36000.22"||m.Memory.Total!="524288"||
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

// The production router's BusyBox ash 1.37 rejects "sh -s" with exit 245.
// Our CI host's /bin/sh may accept it, so guard against that regression with
// a shell that deliberately rejects -s yet otherwise runs the real collector.
func TestMetricsCollectorWithoutDashS(t *testing.T) {
	script, err := assets.ReadFile("scripts/kas-sys-metrics.sh")
	if err != nil { t.Fatal(err) }
	sys, proc := fixtureMetricsRoots(t)
	shell := filepath.Join(t.TempDir(), "busybox-compatible-sh")
	wrapper := "#!/bin/sh\ncase \"$1\" in -s) echo 'Invalid option \"-s\"' >&2; exit 245 ;; esac\nexec /bin/sh \"$@\"\n"
	if err := os.WriteFile(shell, []byte(wrapper), 0700); err != nil { t.Fatal(err) }
	m, err := runMetricsCollectorWithShell(context.Background(), shell, script, sys, proc)
	if err != nil { t.Fatal("BusyBox-compatible invocation failed:", err) }
	if m.Load.Status != "PASS" || m.Uptime.Status != "PASS" || m.Memory.Status != "PASS" {
		t.Fatalf("collector did not produce expected metrics: %+v", m)
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

// Stage A: the optional storage block is a backwards-compatible
// additive field. Collector 0.1.0 payloads (no storage) stay valid; 0.2.0
// payloads may omit the block or carry a strictly validated one, and a
// 0.1.0 payload that claims a storage block is rejected as inconsistent.
func TestMetricsStorageVersionedContract(t *testing.T){
	baseV1:=`{"schema":"router-metrics/v1","tool":"kas-sys-metrics.sh","tool_version":"%s","exit_code":0,`+
		`"temperature":{"status":"UNKNOWN"},"load":{"status":"UNKNOWN"},"uptime":{"status":"UNKNOWN"},`+
		`"memory":{"status":"UNKNOWN"},"swap":{"status":"N/A"}`
	validStorage:=`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"49152","total_kb":"100352","source":"df+proc_mounts","observed_utc":"2026-11-09T18:00:00Z","note":"filesystem-level df capacity"}`
	p:=func(toolVersion,storage string)string{
		return fmt.Sprintf(baseV1,toolVersion)+storage+`}`
	}
	for _,tc:=range []struct{ name string; payload string; want bool }{
		{"old v1 without storage",p("0.1.0",""),true},
		{"old v1 claiming storage",p("0.1.0",validStorage),false},
		{"new v1 without storage",p("0.2.0",""),true},
		{"new v1 valid storage",p("0.2.0",validStorage),true},
		{"new v1 external ext4",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"external","fstype":"ext4","mount_point":"/opt","free_kb":"1000","total_kb":"2000","source":"df+proc_mounts","observed_utc":"2026-11-09T18:00:00Z","note":"n"}`),true},
		{"new v1 ram tmpfs",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"ram","fstype":"tmpfs","mount_point":"/opt","free_kb":"1","total_kb":"2","source":"df+proc_mounts","observed_utc":"2026-11-09T18:00:00Z","note":"n"}`),true},
		{"new v1 unknown honest",p("0.2.0",`,"storage":{"status":"UNKNOWN","path":"/opt","mount_class":"unknown","fstype":"unknown","mount_point":"unknown","free_kb":"","total_kb":"","source":"none","observed_utc":"unknown","note":"n"}`),true},
		{"new v1 na honest",p("0.2.0",`,"storage":{"status":"N/A","path":"/opt","mount_class":"unknown","fstype":"unknown","mount_point":"unknown","free_kb":"","total_kb":"","source":"none","observed_utc":"unknown","note":"n"}`),true},
		{"bad status",p("0.2.0",`,"storage":{"status":"OK","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"bad mount class",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"cloud","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"bad source",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"magic","observed_utc":"unknown","note":"n"}`),false},
		{"free over total",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"3000","total_kb":"2000","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"zero total",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"0","total_kb":"0","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"total over bound",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"10000000000","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"nonnumeric free",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"12.5","total_kb":"2000","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"negative free",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"-5","total_kb":"2000","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"unknown status with numbers",p("0.2.0",`,"storage":{"status":"UNKNOWN","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"100","total_kb":"2000","source":"proc_mounts","observed_utc":"unknown","note":"n"}`),false},
		{"uppercase fstype",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"external","fstype":"EXT4","mount_point":"/opt","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`),false},
		{"control byte in note",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"a\u0001b"}`),false},
		{"bad timestamp",p("0.2.0",`,"storage":{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"yesterday","note":"n"}`),false},
		{"empty path",p("0.2.0",`,"storage":{"status":"PASS","path":"","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`),false},
	}{
		var got systemMetrics
		_ = json.Unmarshal([]byte(tc.payload),&got)
		if validateMetrics(&got)!=tc.want{t.Fatalf("%s: want %v",tc.name,tc.want)}
	}
}

// End-to-end collector runs over injected /opt, mount-table and df fixtures
// (KAS_OPT_ROOT / KAS_MOUNTS_SRC / KAS_DF_BIN are test-only injections; the
// production Go adapter passes none). Mirrors the KN-3811 FIELD shape:
// internal UBIFS via the root mount, plus EXT4, tmpfs, ambiguity and every
// fail-closed UNKNOWN/N-A branch.
func TestMetricsCollectorStorageFixtures(t *testing.T){
	script,err:=assets.ReadFile("scripts/kas-sys-metrics.sh")
	if err!=nil{t.Fatal(err)}
	newFixture:=func(t *testing.T,mounts,dfOut string,dfFail,dfMissing bool,optRoot string)(string,string,string,string){
		t.Helper()
		root:=t.TempDir()
		proc:=filepath.Join(root,"proc")
		sys:=filepath.Join(root,"sys")
		if err:=os.MkdirAll(filepath.Join(sys,"class"),0700);err!=nil{t.Fatal(err)}
		if err:=os.MkdirAll(proc,0700);err!=nil{t.Fatal(err)}
		for name,data:=range map[string]string{
			"proc/loadavg": "0.25 0.50 0.75 1/100 123\n",
			"proc/uptime":  "36000.22 20000.00\n",
			"proc/meminfo": "MemTotal: 524288 kB\nMemAvailable: 262144 kB\n",
		}{
			if err:=os.WriteFile(filepath.Join(root,name),[]byte(data),0600);err!=nil{t.Fatal(err)}
		}
		mountsSrc:=filepath.Join(root,"mounts-unreadable-absent")
		if mounts!=""{
			mountsSrc=filepath.Join(root,"mounts")
			if err:=os.WriteFile(mountsSrc,[]byte(mounts),0600);err!=nil{t.Fatal(err)}
		}
		dfPath:=filepath.Join(root,"df-fixture-missing")
		if !dfMissing{
			dfPath=filepath.Join(root,"df-fixture.sh")
			body:="#!/bin/sh\nexit 1\n"
			if !dfFail{
				body="#!/bin/sh\ncat <<'KASDFEOF'\nFilesystem 1024-blocks Used Available Capacity Mounted on\n"+dfOut+"\nKASDFEOF\n"
			}
			if err:=os.WriteFile(dfPath,[]byte(body),0700);err!=nil{t.Fatal(err)}
		}
		return sys,proc,mountsSrc,dfPath
	}
	for _,tc:=range []struct{
		name string
		mounts,dfOut string
		dfFail,dfMissing bool
		optRoot string
		status,class,fstype,mp,freeKb,totalKb,source string
	}{
		{"internal_ubifs_root_mount","ubi0:rootfs / ubifs rw 0 0\ntmpfs /opt/tmp tmpfs rw 0 0\n",
			"ubi0:rootfs 100352 51200 49152 51% /",false,false,"",
			"PASS","internal","ubifs","/","49152","100352","df+proc_mounts"},
		{"external_ext4_bind_with_escaped_parent","/dev/sda1 /tmp/mnt/Store\\040One ext4 rw 0 0\n/tmp/mnt/Store\\040One/entware /opt ext4 rw 0 0\n",
			"ubivol 100352 51200 49152 51% /opt",false,false,"",
			"PASS","external","ext4","/opt","49152","100352","df+proc_mounts"},
		{"tmpfs_opt_is_ram_not_flash","tmpfs /opt tmpfs rw 0 0\n",
			"none 1024 0 1024 0% /opt",false,false,"",
			"PASS","ram","tmpfs","/opt","1024","1024","df+proc_mounts"},
		{"no_opt_na","/dev/sda1 /tmp/mnt/Disk ext4 rw 0 0\n",
			"",true,false,"absent-opt",
			"N/A","unknown","unknown","unknown","","","none"},
		{"garbled_df_unknown","ubi0:rootfs / ubifs rw 0 0\n",
			"garbage nonsense line",false,false,"",
			"UNKNOWN","internal","ubifs","/","","","proc_mounts"},
		{"free_over_total_unknown","ubi0:rootfs / ubifs rw 0 0\n",
			"ubi0:rootfs 100 51200 49152 51% /",false,false,"",
			"UNKNOWN","internal","ubifs","/","","","proc_mounts"},
		{"zero_free_honest_pass","ubi0:rootfs / ubifs rw 0 0\n",
			"ubi0:rootfs 100352 100352 0 100% /",false,false,"",
			"PASS","internal","ubifs","/","0","100352","df+proc_mounts"},
		{"ambiguous_deepest_unknown_class","ubiA /opt ubifs rw 0 0\nubiB /opt ext4 rw 0 0\n",
			"ubiX 100352 51200 49152 51% /opt",false,false,"",
			"PASS","unknown","unknown","unknown","49152","100352","df"},
		{"mounts_unreadable_df_only","",
			"ubivol 100352 51200 49152 51% /opt",false,false,"",
			"PASS","unknown","unknown","unknown","49152","100352","df"},
		{"df_binary_missing","ubi0:rootfs / ubifs rw 0 0\n",
			"",false,true,"",
			"UNKNOWN","internal","ubifs","/","","","proc_mounts"},
	}{
		t.Run(tc.name,func(t *testing.T){
			optRoot:=tc.optRoot
			if optRoot==""{ optRoot="/opt" }
			if optRoot=="absent-opt"{ optRoot=filepath.Join(t.TempDir(),"opt-not-there") }
			sys,proc,mountsSrc,dfPath:=newFixture(t,tc.mounts,tc.dfOut,tc.dfFail,tc.dfMissing,optRoot)
			m,err:=runMetricsCollectorWithShell(context.Background(),"/bin/sh",script,sys,proc,
				"KAS_OPT_ROOT="+optRoot,"KAS_MOUNTS_SRC="+mountsSrc,"KAS_DF_BIN="+dfPath)
			if err!=nil{t.Fatal(err)}
			s:=m.Storage
			if s==nil{t.Fatal("collector 0.2.0 must emit the storage block")}
			if s.Status!=tc.status||s.MountClass!=tc.class||s.Fstype!=tc.fstype||s.MountPoint!=tc.mp||
				s.FreeKB!=tc.freeKb||s.TotalKB!=tc.totalKb||s.Source!=tc.source{
				t.Fatalf("unexpected storage: %+v",s)
			}
			if s.Path!=optRoot{t.Fatalf("path %q want %q",s.Path,optRoot)}
		})
	}
}

// Hostile-input follow-up to stage A: hostile strings, missing
// provenance fields and oversized values must be rejected or bounded at the
// API contract level. XSS text is deliberately inert (the UI renders text
// nodes only), but it stays inside the length bounds and never passes with a
// missing/empty source, absent timestamp or control bytes.
func TestMetricsStorageHostileAndMissingFields(t *testing.T){
	base:=`{"schema":"router-metrics/v1","tool":"kas-sys-metrics.sh","tool_version":"0.2.0","exit_code":0,`+
		`"temperature":{"status":"UNKNOWN"},"load":{"status":"UNKNOWN"},"uptime":{"status":"UNKNOWN"},`+
		`"memory":{"status":"UNKNOWN"},"swap":{"status":"N/A"},"storage":%s}`
	xss:=`<script>alert(1)</script>`
	long:=strings.Repeat("a",201)
	ok200:=strings.Repeat("a",200)
	for _,tc:=range []struct{ name,storage string; want bool }{
		// missing source key: zero value "" is not in the source enum
		{"missing source key",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","observed_utc":"unknown","note":"n"}`,false},
		{"empty source",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"","observed_utc":"unknown","note":"n"}`,false},
		// missing timestamp on PASS: empty never matches the bounded timestamp form
		{"missing observed_utc on PASS",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"","note":"n"}`,false},
		// note is optional text, its absence stays valid
		{"missing note",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown"}`,true},
		// hostile strings are inert text, but strictly length-bounded
		{"xss mount_point stays bounded text",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"`+xss+`","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`,true},
		{"xss path stays bounded text",`{"status":"PASS","path":"`+xss+`","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`,true},
		{"mount_point over 200 chars",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"`+long+`","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`,false},
		{"mount_point exactly 200 chars",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"`+ok200+`","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`,true},
		{"path over 200 chars",`{"status":"PASS","path":"`+long+`","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`,false},
		{"note over 300 chars",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"`+strings.Repeat("a",301)+`"}`,false},
		// control bytes and shell metacharacters in display fields
		{"control byte in mount_point",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubifs","mount_point":"/opt\u0001evil","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`,false},
		{"newline in fstype",`{"status":"PASS","path":"/opt","mount_class":"internal","fstype":"ubi\nfs","mount_point":"/","free_kb":"1","total_kb":"2","source":"df","observed_utc":"unknown","note":"n"}`,false},
	}{
		var got systemMetrics
		if err:=json.Unmarshal([]byte(fmt.Sprintf(base,tc.storage)),&got);err!=nil{t.Fatalf("%s: %v",tc.name,err)}
		if validateMetrics(&got)!=tc.want{t.Fatalf("%s: want %v",tc.name,tc.want)}
	}
}
