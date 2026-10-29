package main

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func releaseFixture(names ...string) []byte {
	assets := []map[string]any{}
	for i, name := range names {
		assets = append(assets, map[string]any{"id": i + 1, "name": name, "state": "uploaded", "size": 123, "browser_download_url": "https://github.com/saymer-alt/entware-go/releases/download/latest/" + name})
	}
	raw, _ := json.Marshal(map[string]any{"tag_name": "latest", "assets": assets})
	return raw
}
func TestUpdateAssetIsExactTrustedArchitecture(t *testing.T) {
	raw := releaseFixture("mihomo_1.19.33-1_mipsel-3.4.ipk", "mihomo_1.19.33-2_mipsel-3.4.ipk", "mihomo_1.19.34-1_aarch64-3.10.ipk")
	got, err := selectUpdateAsset(raw, "mipsel-3.4")
	if err != nil || got.Version != "1.19.33" || got.Release != 2 {
		t.Fatal(got, err)
	}
	for _, bad := range [][]byte{releaseFixture("mihomo_1.19.33-1_mipsel-3.4.ipk", "mihomo_1.19.33-1_mipsel-3.4.ipk"), []byte(strings.ReplaceAll(string(raw), "github.com", "evil.invalid")), []byte(strings.ReplaceAll(string(raw), `"latest"`, `"v1"`)), releaseFixture("mihomo_1.19.33-rc.1-1_mipsel-3.4.ipk"), releaseFixture("mihomo_nohf_1.19.33-1_mipsel-3.4.ipk")} {
		if _, err := selectUpdateAsset(bad, "mipsel-3.4"); err == nil {
			t.Fatal("accepted ambiguous/untrusted metadata", string(bad))
		}
	}
	if _, err := selectUpdateAsset(releaseFixture("mihomo_1.19.33-2_armv7-3.2.ipk", "mihomo_nohf_1.19.33-2_armv7-3.2.ipk"), "armv7-3.2"); err != nil {
		t.Fatal("nohf variant blocked normal ARMv7", err)
	}
	if compareRuntimeVersions("1.19.33", "1.19.32") != "older" || compareRuntimeVersions("1.19.33", "1.20.0") != "newer" || compareRuntimeVersions("alpha", "1.20.0") != "unknown" {
		t.Fatal("wrong comparison")
	}
}
func updateRequest(a *app, path, origin, confirm, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:18081"+path, strings.NewReader(body))
	req.Header.Set("Origin", origin)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-KAS-Confirm", confirm)
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, req)
	return w
}
func TestUpdateHTTPGuardsAndSingleWorker(t *testing.T) {
	a := newApp("127.0.0.1:18081", []byte("fixture"))
	a.updater = []byte("fixture")
	started, release := make(chan struct{}, 1), make(chan struct{})
	a.runUpdate = func(script []byte) (int, error) { started <- struct{}{}; <-release; return 0, nil }
	a.updateDigest = func() string { return strings.Repeat("a", 64) }
	a.checkUpdates = func(context.Context) (updateCheck, error) {
		return updateCheck{State: "AVAILABLE", Relation: "newer", AvailableVersion: "1.20.0", Architecture: "mipsel-3.4"}, nil
	}
	for _, tc := range []struct{ origin, confirm, body string }{{"http://evil.test", "update-mihomo", "{}"}, {"http://127.0.0.1:18081", "", "{}"}, {"http://127.0.0.1:18081", "update-mihomo", `{"command":"rm"}`}, {"http://127.0.0.1:18081", "update-mihomo", "{}{}"}} {
		if w := updateRequest(a, "/api/updates/mihomo", tc.origin, tc.confirm, tc.body); w.Code < 400 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	check := updateRequest(a, "/api/updates/check", "http://127.0.0.1:18081", "check-updates", "{}")
	if check.Code != 200 {
		t.Fatal(check.Code, check.Body.String())
	}
	w := updateRequest(a, "/api/updates/mihomo", "http://127.0.0.1:18081", "update-mihomo", "{}")
	if w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	<-started
	if !a.importRunning {
		t.Fatal("maintenance not held")
	}
	if w := updateRequest(a, "/api/updates/mihomo", "http://127.0.0.1:18081", "update-mihomo", "{}"); w.Code != 409 {
		t.Fatal("duplicate updater", w.Code)
	}
	if w := updateRequest(a, "/api/doctor", "http://127.0.0.1:18081", "", "{}"); w.Code != 429 {
		t.Fatal("Doctor overlapped")
	}
	close(release)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		a.mu.Lock()
		done := !a.importRunning
		result := a.updateResult
		a.mu.Unlock()
		if done {
			if result.State != "OK" || result.Outcome != "UNCHANGED" {
				t.Fatal(result)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("worker did not finish")
}
func TestUpdateFailureNeverClaimsRollback(t *testing.T) {
	a := newApp("127.0.0.1:18081", nil)
	a.updater = []byte("fixture")
	a.updateDigest = func() string { return "" }
	a.runUpdate = func([]byte) (int, error) { return 7, errors.New("SECRET private output") }
	a.lastUpdateCheck = updateCheck{State: "AVAILABLE", Relation: "newer", Time: now()}
	w := updateRequest(a, "/api/updates/mihomo", "http://127.0.0.1:18081", "update-mihomo", "{}")
	if w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	for i := 0; i < 1000; i++ {
		a.mu.Lock()
		busy := a.importRunning
		result := a.updateResult
		a.mu.Unlock()
		if !busy {
			b, _ := json.Marshal(result)
			if result.State != "FAIL" || strings.Contains(string(b), "SECRET") || strings.Contains(string(b), "rollback") {
				t.Fatal(string(b))
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("no result")
}
func TestUpdateRunnerDiscardsOutputAndPassesNoArguments(t *testing.T) {
	exit, err := updateCommand([]byte("[ \"$#\" = 0 ] || exit 9\nprintf 'SECRET'\nprintf 'PRIVATE' >&2\nexit 7\n"))
	if err == nil || exit != 7 {
		t.Fatal(fmt.Sprint(exit, err))
	}
}

func TestUpdateMetadataFetchBoundsAndRedirects(t *testing.T) {
	called := 0
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called++; w.Write([]byte(`{"tag_name":"latest"}`)) }))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 302) }))
	defer redirect.Close()
	if _, err := fetchUpdateMetadata(context.Background(), updateClient(), redirect.URL); err == nil || called != 0 {
		t.Fatal("followed redirect", called, err)
	}
	oversized := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(strings.Repeat("x", 1024*1024+1))) }))
	defer oversized.Close()
	if _, err := fetchUpdateMetadata(context.Background(), updateClient(), oversized.URL); err == nil {
		t.Fatal("accepted oversized body")
	}
}
func TestUpdateRequiresFreshCheckAndRejectsOlder(t *testing.T) {
	for _, check := range []updateCheck{{}, {State: "AVAILABLE", Relation: "newer", Time: time.Now().Add(-11 * time.Minute).UTC().Format(time.RFC3339)}, {State: "AVAILABLE", Relation: "older", Time: now()}} {
		a := newApp("127.0.0.1:18081", nil)
		a.updater = []byte("exit 0")
		a.lastUpdateCheck = check
		if w := updateRequest(a, "/api/updates/mihomo", "http://127.0.0.1:18081", "update-mihomo", "{}"); w.Code != 409 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}

func TestInventoryEntwareUpdateTrust(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("protected Entware root trust fixture requires root; root inventory CI runs this test")
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"tag_name":"latest"}`)) }))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	defer server.Close()
	root := t.TempDir()
	bundle := filepath.Join(root, "etc/ssl/certs/ca-certificates.crt")
	if err := os.MkdirAll(filepath.Dir(bundle), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := fetchUpdateMetadata(context.Background(), updateClientForRoot(root), server.URL); err == nil {
		t.Fatal("untrusted TLS certificate accepted")
	}
	data := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if err := os.WriteFile(bundle, data, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := fetchUpdateMetadata(context.Background(), updateClientForRoot(root), server.URL); err != nil {
		t.Fatal("protected Entware roots not used", err)
	}
	if err := os.Chmod(bundle, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err := fetchUpdateMetadata(context.Background(), updateClientForRoot(root), server.URL); err == nil {
		t.Fatal("writable trust bundle accepted")
	}
}
