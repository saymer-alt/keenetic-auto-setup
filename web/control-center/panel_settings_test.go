package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPanelSettingsEndpointExistsOnlyOnLAN(t *testing.T) {
	a := accessApp(t)
	r := httptest.NewRequest("GET", "http://"+a.host+"/api/settings", nil)
	r.RemoteAddr = "192.168.107.10:1"
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("settings endpoint: got %d, want200", w.Code)
	}
}

func settingsRequest(a *app, body, currentAuth string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "http://"+a.currentHost()+"/api/settings", strings.NewReader(body))
	r.RemoteAddr = "192.168.107.10:5"
	r.Header.Set("Origin", "http://"+a.currentHost())
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-KAS-Confirm", "settings")
	if currentAuth != "" {
		r.SetBasicAuth(a.currentPanel().login(), currentAuth)
	}
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	return w
}
func TestSettingsCredentialsPersistAndRevoke(t *testing.T) {
	a := accessApp(t)
	a.settingsPath = filepath.Join(t.TempDir(), "settings.json")
	password := "my-private-panel-password"
	w := settingsRequest(a, `{"port":18081,"auth_mode":"panel","password":"`+password+`"}`, "")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), password) || strings.Contains(w.Body.String(), "hash") {
		t.Fatal("credential response leak", w.Body.String())
	}
	data, err := os.ReadFile(a.settingsPath)
	if err != nil || strings.Contains(string(data), password) {
		t.Fatal("plaintext persistence", err)
	}
	st, _ := os.Stat(a.settingsPath)
	if st.Mode().Perm() != 0600 {
		t.Fatal("nonprivate settings")
	}
	loaded, err := readPanelConfig(a.settingsPath)
	if err != nil || !a.lan.credentialsValid(loaded, "kas", password) {
		t.Fatal("restart credentials failed", err)
	}
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"none"}`, password); w.Code != 403 {
		t.Fatal("cached Basic alone changed settings", w.Code)
	}
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"panel","current_password":"`+password+`","password":"replacement-panel-password"}`, password); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if !a.lan.credentialsValid(a.currentPanel(), "kas", "replacement-panel-password") || a.lan.credentialsValid(a.currentPanel(), "kas", password) {
		t.Fatal("password not revoked")
	}
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"none","current_password":"replacement-panel-password"}`, "replacement-panel-password"); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if a.currentPanel().AuthMode != "none" {
		t.Fatal("did not disable")
	}
}
func TestSettingsGuardsAndDiskFailure(t *testing.T) {
	a := accessApp(t)
	a.settingsPath = filepath.Join(t.TempDir(), "settings.json")
	for _, body := range []string{`{}`, `{"port":0,"auth_mode":"none"}`, `{"port":65536,"auth_mode":"none"}`, `{"port":18081,"auth_mode":"bad"}`, `{"port":18081,"auth_mode":"none","hash":"leak"}`, `{"port":18081,"auth_mode":"none"}{}`, `{"port":18081,"auth_mode":"panel","password":"short"}`} {
		if w := settingsRequest(a, body, ""); w.Code != 400 {
			t.Fatal(body, w.Code, w.Body.String())
		}
	}
	for _, guard := range []string{"Origin", "X-KAS-Confirm", "Content-Type", "Sec-Fetch-Site"} {
		r := httptest.NewRequest("POST", "http://"+a.host+"/api/settings", strings.NewReader(`{"port":18081,"auth_mode":"none"}`))
		r.RemoteAddr = "192.168.107.10:5"
		r.Header.Set("Origin", "http://"+a.host)
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-KAS-Confirm", "settings")
		r.Header.Set(guard, "bad")
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatal(guard, w.Code)
		}
	}
	a.importRunning = true
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"none"}`, ""); w.Code != 409 {
		t.Fatal("busy", w.Code)
	}
	a.importRunning = false
	target := filepath.Join(t.TempDir(), "foreign")
	os.WriteFile(target, []byte("foreign"), 0600)
	os.Symlink(target, a.settingsPath)
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"none"}`, ""); w.Code != 503 {
		t.Fatal(w.Code)
	}
	data, _ := os.ReadFile(target)
	if string(data) != "foreign" || a.lan.panel.Load() != nil {
		t.Fatal("failed persistence mutated live/foreign config")
	}
}
func TestPortConflictAndFailedSavePreserveLiveListener(t *testing.T) {
	initial, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a := newApp(initial.Addr().String(), nil)
	a.lan = &homeLAN{address: a.host, clients: netip.MustParsePrefix("127.0.0.0/8")}
	a.settingsPath = filepath.Join(t.TempDir(), "settings.json")
	_, port, _ := net.SplitHostPort(a.host)
	n, _ := strconv.Atoi(port)
	a.lan.panel.Store(&panelConfig{Version: 1, Port: n, AuthMode: "none"})
	a.listeners = newPanelListeners(a)
	a.listeners.replace(initial)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		a.listeners.shutdown(ctx)
	})
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	_, occupiedPort, _ := net.SplitHostPort(occupied.Addr().String())
	w := settingsRequest(a, `{"port":`+occupiedPort+`,"auth_mode":"none"}`, "")
	if w.Code != 409 || !strings.Contains(w.Body.String(), "PORT_IN_USE") {
		t.Fatal(w.Code, w.Body.String())
	}
	if a.currentHost() != a.host {
		t.Fatal("old address lost on conflict")
	}
	resp, err := http.Get("http://" + a.host + "/api/settings")
	if err != nil {
		t.Fatal("old listener lost", err)
	}
	resp.Body.Close()
	// Reserve a real alternative then release it; the transaction must acquire it.
	alternative, _ := net.Listen("tcp", "127.0.0.1:0")
	nextAddress := alternative.Addr().String()
	_, nextPort, _ := net.SplitHostPort(nextAddress)
	alternative.Close()
	a.settingsPath = filepath.Join(t.TempDir(), "missing", "settings.json")
	w = settingsRequest(a, `{"port":`+nextPort+`,"auth_mode":"none"}`, "")
	if w.Code != 503 || a.currentHost() != a.host {
		t.Fatal("failed save lost old listener", w.Code)
	}
	probe, err := net.Listen("tcp", nextAddress)
	if err != nil {
		t.Fatal("reserved port leaked", err)
	}
	probe.Close()
	a.settingsPath = filepath.Join(t.TempDir(), "settings.json")
	w = settingsRequest(a, `{"port":`+nextPort+`,"auth_mode":"none"}`, "")
	if w.Code != 200 || a.currentHost() != nextAddress {
		t.Fatal("switch failed", w.Code, w.Body.String())
	}
	resp, err = http.Get("http://" + nextAddress + "/api/settings")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatal(resp.StatusCode)
	}
	loaded, err := readPanelConfig(a.settingsPath)
	if err != nil || fmt.Sprint(loaded.Port) != nextPort {
		t.Fatal("new port not persistent", err)
	}
}

func TestEntwareSettingsRequireProofAndFollowRootLock(t *testing.T) {
	a := accessApp(t)
	a.settingsPath = filepath.Join(t.TempDir(), "settings.json")
	a.lan.entwareRoot = t.TempDir()
	credentialFixture(t, a.lan.entwareRoot, "shadow", "root:"+entwareVectors[2]+":19000:0:99999:7:::\n")
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"entware","password":"wrong"}`, ""); w.Code != 400 {
		t.Fatal(w.Code)
	}
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"entware","password":"router-password"}`, ""); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	get := func(user, password string) int {
		r := httptest.NewRequest("GET", "http://"+a.host+"/api/settings", nil)
		r.RemoteAddr = "192.168.107.10:4"
		if user != "" {
			r.SetBasicAuth(user, password)
		}
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		return w.Code
	}
	if get("", "") != 401 || get("kas", "router-password") != 401 || get("root", "router-password") != 200 {
		t.Fatal("root mode auth not enforced")
	}
	// Cached correct credentials cannot outlive a locked root entry.
	credentialFixture(t, a.lan.entwareRoot, "shadow", "root:!"+entwareVectors[2]+":19000:0:99999:7:::\n")
	if get("root", "router-password") != 401 {
		t.Fatal("cached root survives lock")
	}
	credentialFixture(t, a.lan.entwareRoot, "shadow", "root:"+entwareVectors[2]+":19000:0:99999:7:::\n")
	if w := settingsRequest(a, `{"port":18081,"auth_mode":"none","current_password":"router-password"}`, "router-password"); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if get("", "") != 200 {
		t.Fatal("explicit disabled mode failed")
	}
}

func TestStandardHTTPPortAcceptsBrowserNormalizedHost(t *testing.T) {
	a := newApp("192.168.107.1:80", nil)
	a.lan = &homeLAN{address: a.host, clients: netip.MustParsePrefix("192.168.107.0/24")}
	r := httptest.NewRequest("GET", "http://192.168.107.1/api/settings", nil)
	r.RemoteAddr = "192.168.107.10:5"
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	if w.Code != 200 || a.expectedOrigin(r.Host) != "http://192.168.107.1" {
		t.Fatalf("browser normalized port80 rejected: %d", w.Code)
	}
}
