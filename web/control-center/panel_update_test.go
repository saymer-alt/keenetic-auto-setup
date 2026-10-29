package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The disposable aarch64 service lab caught the real Entware behavior the
// worker must tolerate: opkg owns its info files and the aarch64 2022 feed
// writes the package list world-writable (0666) on real installations, while
// the x64 2024 build honors the umask (0600). Ownership evidence stays
// structural; a panel-owned private file keeps the strict mode contract.
func TestPanelIntegrityAcceptsOpkgOwnedWorldWritableList(t *testing.T) {
	root := panelUpdateRoot(t)
	for _, dir := range []string{"bin", "etc/init.d", "share/kas-control-center", "lib/opkg/info"} {
		if e := os.MkdirAll(filepath.Join(root, dir), 0755); e != nil {
			t.Fatal(e)
		}
	}
	payload := []byte("panel binary fixture")
	digest := sha256.Sum256(payload)
	info := "Version=0.0.0~integrity-1\n" +
		"KAS_SOURCE_SHA=" + strings.Repeat("a", 40) + "\n" +
		"Architecture=aarch64-3.10\n" +
		"Channel=experimental\n" +
		"CGO_ENABLED=0\n" +
		"GOARCH=arm64\n" +
		"Binary_SHA256=" + hex.EncodeToString(digest[:]) + "\n"
	files := map[string][]byte{
		"bin/kas-control-center":             payload,
		"share/kas-control-center/BUILD_INFO": []byte(info),
		"etc/init.d/S98kas-control-center":    []byte("#!/bin/sh\n# KAS-CONTROL-CENTER-IPK-v1\n"),
		"lib/opkg/info/kas-control-center.control": []byte(
			"Package: kas-control-center\nVersion: 0.0.0~integrity-1\nArchitecture: aarch64-3.10\n" +
				"Source: " + strings.Repeat("a", 40) + "\nInstalled-Size: 1\n"),
		"lib/opkg/info/kas-control-center.list": []byte(
			"/opt/bin/kas-control-center\n/opt/etc/init.d/S98kas-control-center\n" +
				"/opt/share/kas-control-center/BUILD_INFO\n"),
	}
	for name, body := range files {
		if e := os.WriteFile(filepath.Join(root, name), body, 0644); e != nil {
			t.Fatal(e)
		}
	}
	// The mode opkg itself chose on real aarch64 installations.
	if e := os.Chmod(filepath.Join(root, "lib/opkg/info/kas-control-center.list"), 0666); e != nil {
		t.Fatal(e)
	}
	p := newPanelUpdater(root)
	if e := p.integrity(); e != nil {
		t.Fatalf("world-writable opkg-owned list refused: %v", e)
	}
	// A symlinked or replaced list still refuses; the mode is the only
	// relaxation, never the path or ownership identity.
	listPath := filepath.Join(root, "lib/opkg/info/kas-control-center.list")
	if e := os.Remove(listPath); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink(filepath.Join(root, "share/kas-control-center/BUILD_INFO"), listPath); e != nil {
		t.Fatal(e)
	}
	if e := p.integrity(); e == nil {
		t.Fatal("symlinked opkg list accepted")
	}
}

func TestPanelDurableGateBlocksOtherMutationAfterRestart(t *testing.T) {
	root := panelUpdateRoot(t)
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	p := newPanelUpdater(root)
	if e := p.acquireGate(); e != nil {
		t.Fatal(e)
	}
	a := newApp("127.0.0.1:8081", nil)
	a.panelUpdate = newPanelUpdater(root)
	r := httptest.NewRequest("POST", "http://127.0.0.1:8081/api/doctor", strings.NewReader(`{}`))
	r.Host = "127.0.0.1:8081"
	r.Header.Set("Origin", "http://127.0.0.1:8081")
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	if w.Code != 409 || !strings.Contains(w.Body.String(), "PANEL_UPDATE_BUSY") {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	if e := a.panelUpdate.acquireGate(); e == nil {
		t.Fatal("second gate admitted")
	}
}
func TestPanelStateIsPrivateAndSurvivesNewInstance(t *testing.T) {
	root := panelUpdateRoot(t)
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	p := newPanelUpdater(root)
	if e := p.acquireGate(); e != nil {
		t.Fatal(e)
	}
	j := panelJob{Schema: 1, ID: strings.Repeat("a", 24), State: "RUNNING", Phase: "download", Channel: "experimental"}
	if e := p.writeJob(j); e != nil {
		t.Fatal(e)
	}
	got, e := newPanelUpdater(root).readJob()
	if e != nil || got.ID != j.ID {
		t.Fatalf("%#v %v", got, e)
	}
	st, _ := os.Stat(filepath.Join(p.dir, "job.json"))
	if st.Mode().Perm() != 0600 {
		t.Fatal("public job")
	}
	b, _ := json.Marshal(got)
	if strings.Contains(string(b), "password") {
		t.Fatal("credentials persisted")
	}
}
func TestPanelCheckRequiresExplicitOriginAndNoURLBody(t *testing.T) {
	a := newApp("127.0.0.1:8081", nil)
	for _, body := range []string{`{}`, `{"url":"https://evil.invalid"}`} {
		r := httptest.NewRequest("POST", "http://127.0.0.1:8081/api/updates/panel/check", strings.NewReader(body))
		r.Host = "127.0.0.1:8081"
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-KAS-Confirm", "check-panel")
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		if w.Code != http.StatusForbidden {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
	}
}
func TestPanelWorkerRejectsMissingStageBeforeInstall(t *testing.T) {
	root := panelUpdateRoot(t)
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	p := newPanelUpdater(root)
	p.acquireGate()
	c, _ := panelFixture(t)
	j := panelJob{Schema: 1, ID: strings.Repeat("a", 24), State: "RUNNING", Phase: "queued", Channel: "experimental", Candidate: c}
	p.writeJob(j)
	// Missing private stage is a real preflight failure, not a mocked opkg success.
	if e := p.runWorker(); e == nil {
		t.Fatal("invalid stage accepted")
	}
	got, e := p.readJob()
	if e != nil || got.State != "FAIL" || got.Phase == "install" {
		t.Fatalf("%#v %v", got, e)
	}
}

func TestPanelGateRecheckedByAlreadyAdmittedMutation(t *testing.T) {
	root := panelUpdateRoot(t)
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	p := newPanelUpdater(root)
	p.acquireGate()
	a := newApp("127.0.0.1:8081", nil)
	a.panelUpdate = p
	// Models a request that passed middleware before the update gate was created.
	for _, tc := range []struct {
		handler http.HandlerFunc
		confirm string
	}{{a.handleDoctor, ""}, {a.handleMihomoUpdate, "update-mihomo"}} {
		r := httptest.NewRequest("POST", "http://127.0.0.1:8081/", strings.NewReader(`{}`))
		r.Host = "127.0.0.1:8081"
		r.Header.Set("Origin", "http://127.0.0.1:8081")
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-KAS-Confirm", tc.confirm)
		w := httptest.NewRecorder()
		tc.handler(w, r)
		if !strings.Contains(w.Body.String(), `"error_code":"BUSY"`) {
			t.Fatalf("already admitted request was not blocked: %d %s", w.Code, w.Body.String())
		}
	}
}

func TestPanelLostWorkerIsReportedAsRecoveryNotEndlessProgress(t *testing.T) {
	root := panelUpdateRoot(t)
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	p := newPanelUpdater(root)
	p.acquireGate()
	p.writeJob(panelJob{Schema: 1, ID: strings.Repeat("a", 24), State: "RUNNING", Phase: "install", WorkerPID: 2147483647})
	a := newApp("127.0.0.1:8081", nil)
	a.panelUpdate = p
	w := httptest.NewRecorder()
	a.handlePanelOperation(w, httptest.NewRequest("GET", "/api/updates/panel/operation", nil))
	if !strings.Contains(w.Body.String(), "PANEL_RECOVERY_REQUIRED") {
		t.Fatalf("lost worker reported as progress: %s", w.Body.String())
	}
}

func TestPanelLaunchWorkerUsesSeparateSessionAndPrivateStage(t *testing.T) {
	root := panelUpdateRoot(t)
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	os.MkdirAll(filepath.Join(root, "tmp"), 0755)
	p := newPanelUpdater(root)
	j := panelJob{ID: strings.Repeat("b", 24)}
	os.Mkdir(p.stage(j), 0700)
	script := "#!/bin/sh\nIFS= read -r record < /proc/self/stat\nprintf '%s' \"$record\" > stat\npython3 -c 'import os; open(\"stdio\", \"w\").write(os.readlink(\"/proc/self/fd/1\"))'\nsleep 1\nprintf done > done\n"
	os.WriteFile(filepath.Join(p.stage(j), "runner"), []byte(script), 0700)
	if e := p.launchWorker(j); e != nil {
		t.Fatal(e)
	}
	var record string
	for n := 0; n < 100; n++ {
		b, e := os.ReadFile(filepath.Join(p.stage(j), "stat"))
		if e == nil {
			record = string(b)
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if record == "" {
		t.Fatal("worker never launched")
	}
	i := strings.LastIndex(record, ") ")
	fields := strings.Fields(record[i+2:])
	pid := strings.Fields(record)[0]
	if len(fields) < 4 || fields[3] != pid {
		t.Fatalf("worker session not detached: %s", record)
	}
	for n := 0; n < 150; n++ {
		if _, e := os.Stat(filepath.Join(p.stage(j), "done")); e == nil {
			b, e := os.ReadFile(filepath.Join(p.stage(j), "stdio"))
			if e != nil || strings.TrimSpace(string(b)) != "/dev/null" {
				t.Fatalf("worker retained parent stdio: %q %v", b, e)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("worker did not finish independently")
}

func panelUpdateRoot(t *testing.T) string {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("private root-owned updater fixtures run in mandatory root CI")
	}
	return t.TempDir()
}

func TestPanelGateCannotReuseHistoricalSuccessAfterInterruptedAdmission(t *testing.T) {
	root := panelUpdateRoot(t)
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	p := newPanelUpdater(root)
	p.acquireGate()
	p.writeJob(panelJob{Schema: 1, ID: strings.Repeat("a", 24), State: "OK", Phase: "complete"})
	a := newApp("127.0.0.1:8081", nil)
	a.panelUpdate = p
	w := httptest.NewRecorder()
	a.handlePanelOperation(w, httptest.NewRequest("GET", "/api/updates/panel/operation", nil))
	if !strings.Contains(w.Body.String(), "PANEL_RECOVERY_REQUIRED") {
		t.Fatalf("historical success reused under durable gate: %s", w.Body.String())
	}
}
