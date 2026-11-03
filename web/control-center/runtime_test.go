package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDoctorSummaryRequiresCompleteConsistentFooter(t *testing.T) {
	footer := "=== Mihomo Doctor Summary ===\nOK:   4\nWARN: 2\nFAIL: 0\nINFO: 3\n\n[WARN] Overall status: WARN\n"
	s := parseDoctorSummary("old output\n"+footer, 1)
	if s == nil || s.Verdict != "WARN" || s.Warn != 2 || s.OK != 4 {
		t.Fatalf("missing actual findings: %+v", s)
	}
	for _, bad := range []string{footer + "extra\n", strings.Replace(footer, "FAIL: 0", "FAIL: 1", 1), footer + footer, "[OK] Overall status: OK", strings.Replace(footer, "WARN: 2", "WARN: -1", 1)} {
		if got := parseDoctorSummary(bad, 1); got != nil {
			t.Fatalf("accepted malformed summary %+v", got)
		}
	}
	if parseDoctorSummary(footer, 0) != nil {
		t.Fatal("exit mismatch accepted")
	}
	if parseDoctorSummary("\x1b[32m"+strings.ReplaceAll(footer, "\n", "\x1b[0m\n"), 1) == nil {
		t.Fatal("ANSI output rejected")
	}
}
func TestRuntimeVersionBoundedLocalResponse(t *testing.T) {
	for _, tc := range []struct {
		body   string
		status int
		want   string
	}{
		{`{"meta":true,"version":"1.19.33"}`, 200, "1.19.33"},
		{`{"meta":true,"version":"<secret>"}`, 200, ""},
		{`{"version":"1.19.33"}`, 200, ""},
		{`{"meta":true,"version":"1.19.33"}`, 401, ""},
		{strings.Repeat("x", 5000), 200, ""},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/version" || r.Header.Get("Authorization") != "Bearer fixture" {
				t.Error("wrong fixed request")
			}
			w.WriteHeader(tc.status)
			w.Write([]byte(tc.body))
		}))
		got := readMihomoVersion(context.Background(), srv.Client(), srv.URL+"/version", "fixture")
		srv.Close()
		if got != tc.want {
			t.Fatalf("version %q want %q", got, tc.want)
		}
	}
}
func TestProcessEvidenceMatchesExecutableNotName(t *testing.T) {
	root := t.TempDir()
	proc := filepath.Join(root, "proc")
	binary := filepath.Join(root, "mihomo")
	os.Mkdir(proc, 0700)
	os.Mkdir(filepath.Join(proc, "1"), 0700)
	os.Mkdir(filepath.Join(proc, "self"), 0700)
	os.WriteFile(filepath.Join(proc, "self", "stat"), []byte("fixture"), 0600)
	os.WriteFile(filepath.Join(proc, "mounts"), []byte("proc /proc proc rw 0 0\n"), 0600)
	os.WriteFile(binary, []byte("binary"), 0700)
	os.Mkdir(filepath.Join(proc, "123"), 0700)
	os.Symlink(binary, filepath.Join(proc, "123", "exe"))
	os.WriteFile(filepath.Join(proc, "123", "stat"), []byte("123 (name with ) brackets) S "+strings.Repeat("0 ", 25)), 0600)
	if got := processEvidence(proc, []string{binary}); got != "running" {
		t.Fatal(got)
	}
	os.Remove(filepath.Join(proc, "123", "exe"))
	os.Symlink("/bin/sh", filepath.Join(proc, "123", "exe"))
	if got := processEvidence(proc, []string{binary}); got != "stopped" {
		t.Fatal("trusted process name", got)
	}
	os.WriteFile(filepath.Join(proc, "mounts"), []byte("proc /proc proc rw,hidepid=2 0 0\n"), 0600)
	if got := processEvidence(proc, []string{binary}); got != "unknown" {
		t.Fatal("restricted proc falsely reported stopped", got)
	}
	if got := processEvidence(filepath.Join(root, "missing"), []string{binary}); got != "unknown" {
		t.Fatal(got)
	}
}
func TestPackageVersionDoesNotExposeOtherFields(t *testing.T) {
	if got := parsePackageVersion("Package: magitrickle\nVersion: 0.8.2-1\nSecret: private\n", "magitrickle"); got != "0.8.2-1" {
		t.Fatal(got)
	}
	for _, bad := range []string{"Package: foreign\nVersion: 1.2\n", "Package: magitrickle\nVersion: 1\nVersion: 2\n", "Package: magitrickle\nVersion: <script>\n"} {
		if parsePackageVersion(bad, "magitrickle") != "" {
			t.Fatal("accepted invalid metadata")
		}
	}
}

func TestDoctorHTTPReportsFindingsForNonzeroDiagnosticExit(t *testing.T) {
	for _, tc := range []struct {
		verdict          string
		warn, fail, exit int
	}{{"OK", 0, 0, 0}, {"WARN", 1, 0, 1}, {"FAIL", 1, 2, 2}} {
		footer := fmt.Sprintf("=== Mihomo Doctor Summary ===\nOK:   3\nWARN: %d\nFAIL: %d\nINFO: 4\n\n[%s] Overall status: %s\n", tc.warn, tc.fail, tc.verdict, tc.verdict)
		// Real shell child with a known diagnostic footer/exit, no service commands.
		script := fmt.Sprintf("cat <<'REPORT'\n%sREPORT\nexit %d\n", footer, tc.exit)
		a := newApp("127.0.0.1:18081", []byte(script))
		req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:18081/api/doctor", strings.NewReader("{}"))
		req.Header.Set("Origin", "http://127.0.0.1:18081")
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, req)
		var got apiResult
		if json.Unmarshal(w.Body.Bytes(), &got) != nil || w.Code != 200 || got.Summary == nil || got.Summary.Verdict != tc.verdict || got.ErrorCode != "" || got.State != "UNKNOWN" {
			t.Fatalf("wrong diagnostic result: %s", w.Body.String())
		}
	}
}
