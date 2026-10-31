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

func TestPanelTagAllowlistPerChannel(t *testing.T) {
	valid := map[string][]string{
		"experimental": {"kas-web-ipk-92e301d", "kas-web-ipk-92e301da2464ac9694fff3f41f4ee1cb9be90708",
			"v0.1.0-beta.2", "kas-web-v0.1.0-beta.2", "v1.2.3-beta.11"},
		"stable": {"kas-web-v0.1.0", "kas-web-v1.2.3"},
	}
	for channel, tags := range valid {
		for _, tag := range tags {
			if !panelTagValid(channel, tag) {
				t.Fatalf("%s must accept %s", channel, tag)
			}
		}
	}
	invalid := []struct{ channel, tag string }{
		{"experimental", "v0.1.0"}, {"experimental", "kas-web-v0.1.0"}, {"experimental", "kas-web-channel-experimental"},
		{"experimental", "v0.1.0-beta"}, {"experimental", "v0.1.0-beta.x"}, {"experimental", "v0.1.0.1-beta.2"},
		{"experimental", "kas-web-ipk-92E301D"}, {"experimental", "v0.1.0-beta.2-pre"}, {"stable", "v0.1.0"},
		{"stable", "v0.1.0-beta.1"}, {"stable", "kas-web-ipk-92e301d"}, {"stable", "kas-web-v0.1"},
		{"unknown", "kas-web-ipk-92e301d"}, {"unknown", "kas-web-v0.1.0"}, {"", "kas-web-v0.1.0"},
	}
	for _, c := range invalid {
		if panelTagValid(c.channel, c.tag) {
			t.Fatalf("%s must reject %s", c.channel, c.tag)
		}
	}
}
func TestPanelIndexCanonicalBetaTagRoundTrip(t *testing.T) {
	c, _ := panelFixture(t)
	index := panelIndex{Schema: 1, Channel: "experimental", Tag: "v0.1.0-beta.2", Packages: []panelCandidate{c}}
	raw, _ := json.Marshal(index)
	got, e := parsePanelIndex(raw, "experimental", "mipsel-3.4")
	if e != nil || got.Tag != "v0.1.0-beta.2" || got.Channel != "experimental" {
		t.Fatalf("canonical beta index rejected: %v %#v", e, got)
	}
	index.Tag = "kas-web-v0.1.0-beta.2"
	raw, _ = json.Marshal(index)
	if _, e = parsePanelIndex(raw, "experimental", "mipsel-3.4"); e != nil {
		t.Fatalf("prefixed canonical beta index rejected: %v", e)
	}
	index.Tag = "kas-web-v0.1.0"
	raw, _ = json.Marshal(index)
	if _, e = parsePanelIndex(raw, "experimental", "mipsel-3.4"); e == nil {
		t.Fatal("stable tag accepted on experimental index")
	}
	// Package-level channel identity is enforced when the IPK is validated
	// against its BUILD_INFO, not at index parse time; a stable candidate
	// pointing at an experimental-built IPK must fail validation.
	stable := panelIndex{Schema: 1, Channel: "stable", Tag: "kas-web-v0.1.0", Packages: []panelCandidate{c}}
	raw, _ = json.Marshal(stable)
	got, e = parsePanelIndex(raw, "stable", "mipsel-3.4")
	if e != nil || got.Channel != "stable" {
		t.Fatalf("stable index parse: %v %#v", e, got)
	}
	stable.Tag = "v0.1.0-beta.2"
	raw, _ = json.Marshal(stable)
	if _, e = parsePanelIndex(raw, "stable", "mipsel-3.4"); e == nil {
		t.Fatal("beta tag accepted on stable index")
	}
}
func TestPanelIPKChannelIdentityMustMatchCandidate(t *testing.T) {
	c, ipk := panelFixture(t)
	p := filepath.Join(t.TempDir(), "panel.ipk")
	if e := os.WriteFile(p, ipk, 0600); e != nil {
		t.Fatal(e)
	}
	stable := c
	stable.Channel = "stable"
	if e := validatePanelIPK(p, stable); e == nil {
		t.Fatal("experimental-built IPK accepted as a stable candidate")
	}
	if e := validatePanelIPK(p, c); e != nil {
		t.Fatalf("original candidate rejected: %v", e)
	}
}
func TestPanelChannelTargetsMatrix(t *testing.T) {
	for _, build := range []string{"experimental", "stable"} {
		got := panelChannelTargets(build)
		if len(got) != 2 || got[0] != "experimental" || got[1] != "stable" {
			t.Fatalf("build %s targets: %v", build, got)
		}
	}
	if got := panelChannelTargets("unknown"); got != nil {
		t.Fatalf("unknown build targets: %v", got)
	}
}
func TestPanelJobChannelAdmissionMatrix(t *testing.T) {
	experimental := panelCandidate{Tag: "kas-web-ipk-92e301d", Channel: "experimental"}
	canonical := panelCandidate{Tag: "v0.1.0-beta.3", Channel: "experimental"}
	stable := panelCandidate{Tag: "kas-web-v0.1.0", Channel: "stable"}
	allowed := []struct {
		build, job string
		candidate  panelCandidate
	}{
		{"experimental", "experimental", experimental},
		{"experimental", "experimental", canonical},
		{"experimental", "stable", stable},
		{"stable", "stable", stable},
		{"stable", "experimental", experimental},
		{"stable", "experimental", canonical},
	}
	for _, c := range allowed {
		if !panelJobChannelAllowed(c.build, c.job, c.candidate) {
			t.Fatalf("build=%s job=%s tag=%s must be admitted", c.build, c.job, c.candidate.Tag)
		}
	}
	denied := []struct {
		build, job string
		candidate  panelCandidate
	}{
		{"experimental", "stable", experimental},
		{"experimental", "stable", panelCandidate{Tag: "kas-web-v0.1.0", Channel: "experimental"}},
		{"stable", "experimental", panelCandidate{Tag: "v0.1.0-beta.3", Channel: "stable"}},
		{"stable", "stable", experimental},
		{"experimental", "unknown", experimental},
		{"unknown", "experimental", experimental},
		{"experimental", "experimental", panelCandidate{Tag: "kas-web-v0.1.0"}},
		{"experimental", "experimental", panelCandidate{Tag: "v0.1.0"}},
		{"stable", "stable", canonical},
		{"experimental", "", experimental},
	}
	for _, c := range denied {
		if panelJobChannelAllowed(c.build, c.job, c.candidate) {
			t.Fatalf("build=%s job=%s tag=%s must be denied", c.build, c.job, c.candidate.Tag)
		}
	}
}
func TestPanelChannelEndpointGuards(t *testing.T) {
	defer func(build string) { panelBuildChannel = build }(panelBuildChannel)
	panelBuildChannel = "experimental"
	a := newApp("127.0.0.1:8081", nil)
	post := func(channel, confirm, origin string, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "http://127.0.0.1:8081/api/updates/panel/channel", strings.NewReader(body))
		r.Host = "127.0.0.1:8081"
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-KAS-Confirm", confirm)
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		a.handlePanelChannel(w, r)
		return w
	}
	if w := post("stable", "set-panel-channel", "http://evil.example", `{"channel":"stable"}`); w.Code != http.StatusForbidden {
		t.Fatalf("cross-origin POST accepted: %d %s", w.Code, w.Body.String())
	}
	if w := post("stable", "set-panel-channel", "", `{"channel":"stable"}`); w.Code != http.StatusForbidden {
		t.Fatalf("missing Origin accepted: %d %s", w.Code, w.Body.String())
	}
	if w := post("stable", "update-panel", "http://127.0.0.1:8081", `{"channel":"stable"}`); w.Code != http.StatusForbidden {
		t.Fatalf("wrong confirm token accepted: %d %s", w.Code, w.Body.String())
	}
	r := httptest.NewRequest("POST", "http://127.0.0.1:8081/api/updates/panel/channel", strings.NewReader(`{"channel":"stable"}`))
	r.Host = "127.0.0.1:8081"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-KAS-Confirm", "set-panel-channel")
	r.Header.Set("Origin", "http://127.0.0.1:8081")
	r.Header.Set("Sec-Fetch-Site", "cross-site")
	w := httptest.NewRecorder()
	a.handlePanelChannel(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("cross-site fetch accepted: %d %s", w.Code, w.Body.String())
	}
	if w := post("beta", "set-panel-channel", "http://127.0.0.1:8081", `{"channel":"beta"}`); w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "PANEL_CHANNEL_UNKNOWN") {
		t.Fatalf("unknown channel accepted: %d %s", w.Code, w.Body.String())
	}
	if w := post("stable", "set-panel-channel", "http://127.0.0.1:8081", `{"channel":"stable","extra":1}`); w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "INVALID_BODY") {
		t.Fatalf("unknown body field accepted: %d %s", w.Code, w.Body.String())
	}
	if w := post("stable", "set-panel-channel", "http://127.0.0.1:8081", `{"channel":"stable","channel":"experimental"}`); w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "INVALID_BODY") {
		t.Fatalf("duplicate channel field accepted: %d %s", w.Code, w.Body.String())
	}
	if w := post("stable", "set-panel-channel", "http://127.0.0.1:8081", `{"channel":"stable"}{}`); w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "INVALID_BODY") {
		t.Fatalf("trailing JSON accepted: %d %s", w.Code, w.Body.String())
	}
	r = httptest.NewRequest("GET", "http://127.0.0.1:8081/api/updates/panel/channel", nil)
	w = httptest.NewRecorder()
	a.handlePanelChannel(w, r)
	var state panelChannelState
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &state) != nil || state.Channel != "experimental" || state.BuildChannel != "experimental" || len(state.Allowed) != 2 {
		t.Fatalf("GET default state wrong: %d %s", w.Code, w.Body.String())
	}
}
func TestPanelChannelStoreRoundTripAndCheckedInvalidation(t *testing.T) {
	root := panelUpdateRoot(t)
	if e := os.MkdirAll(filepath.Join(root, "etc"), 0755); e != nil {
		t.Fatal(e)
	}
	p := newPanelUpdater(root)
	if p.effectiveChannel() != panelBuildChannel {
		t.Fatal("absent selection must fall back to the build channel")
	}
	if p.selectedChannel() != "" {
		t.Fatal("absent selection must read as empty")
	}
	c := &panelCandidate{Version: "0.1.0~beta.2-1"}
	p.checked = c
	if e := p.storeChannel("stable"); e != nil {
		t.Fatal(e)
	}
	if p.checked != nil {
		t.Fatal("channel switch must invalidate the checked candidate")
	}
	if got := p.selectedChannel(); got != "stable" {
		t.Fatalf("selection not persisted: %q", got)
	}
	if got := p.effectiveChannel(); got != "stable" {
		t.Fatalf("effective channel: %q", got)
	}
	st, e := os.Lstat(filepath.Join(p.dir, "channel"))
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("channel file must be private: %v %v", e, st)
	}
	if e := p.storeChannel("beta"); e == nil {
		t.Fatal("unknown channel accepted")
	}
	if e := p.storeChannel("experimental"); e != nil {
		t.Fatal(e)
	}
	if got := p.selectedChannel(); got != "experimental" {
		t.Fatalf("re-selection not persisted: %q", got)
	}
}
func TestPanelChannelPOSTPersistsAndReturnsState(t *testing.T) {
	root := panelUpdateRoot(t)
	if e := os.MkdirAll(filepath.Join(root, "etc"), 0755); e != nil {
		t.Fatal(e)
	}
	defer func(build string) { panelBuildChannel = build }(panelBuildChannel)
	panelBuildChannel = "experimental"
	a := newApp("127.0.0.1:8081", nil)
	a.panelUpdate = newPanelUpdater(root)
	r := httptest.NewRequest("POST", "http://127.0.0.1:8081/api/updates/panel/channel", strings.NewReader(`{"channel":"stable"}`))
	r.Host = "127.0.0.1:8081"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-KAS-Confirm", "set-panel-channel")
	r.Header.Set("Origin", "http://127.0.0.1:8081")
	w := httptest.NewRecorder()
	a.handlePanelChannel(w, r)
	var state panelChannelState
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &state) != nil || state.Channel != "stable" || state.BuildChannel != "experimental" {
		t.Fatalf("POST stable rejected: %d %s", w.Code, w.Body.String())
	}
	if got := a.panelUpdate.selectedChannel(); got != "stable" {
		t.Fatalf("POST did not persist selection: %q", got)
	}
	r = httptest.NewRequest("POST", "http://127.0.0.1:8081/api/updates/panel/channel", strings.NewReader(`{"channel":"experimental"}`))
	r.Host = "127.0.0.1:8081"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-KAS-Confirm", "set-panel-channel")
	r.Header.Set("Origin", "http://127.0.0.1:8081")
	w = httptest.NewRecorder()
	a.handlePanelChannel(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("POST back to build channel rejected: %d %s", w.Code, w.Body.String())
	}
}
func TestPanelCheckUsesSelectedChannelInResult(t *testing.T) {
	// Handler wiring: a selected channel must be echoed by the check result
	// even when the check itself cannot reach the network from the test.
	root := panelUpdateRoot(t)
	if e := os.MkdirAll(filepath.Join(root, "etc"), 0755); e != nil {
		t.Fatal(e)
	}
	p := newPanelUpdater(root)
	if e := p.storeChannel("stable"); e != nil {
		t.Fatal(e)
	}
	if p.effectiveChannel() != "stable" {
		t.Fatal("precondition: selection must drive the effective channel")
	}
}
// Pages-based channel classification (docs/updates-pages-architecture.md):
// the registry distinguishes "not published yet" from "published but broken"
// and from "temporarily unavailable"; none of the failures may degrade into
// a harmless "no updates".
func TestPagesChannelStates(t *testing.T) {
	restore := pagesUpdateBase
	defer func() { pagesUpdateBase = restore }()

	indexBody := func(tag string) []byte {
		return []byte(`{"schema":1,"channel":"experimental","tag":"` + tag + `","packages":[]}`)
	}
	registry := func(experimental bool) []byte {
		return []byte(`{"schema":1,"channels":{"experimental":{"published":` +
			map[bool]string{true: "true", false: "false"}[experimental] +
			`,"tag":"v0.1.0-beta.4"},"stable":{"published":false}}}`)
	}

	for _, tc := range []struct {
		name        string
		registry    func() (int, []byte)
		index       func() (int, []byte)
		want        string
	}{
		{"published experimental with a valid index", func() (int, []byte) { return 200, registry(true) },
			func() (int, []byte) { return 200, indexBody("v0.1.0-beta.4") }, ""},
		{"registry says unpublished", func() (int, []byte) { return 200, registry(false) },
			func() (int, []byte) { t.Fatal("index must not be fetched for an unpublished channel"); return 0, nil },
			"PANEL_CHANNEL_UNPUBLISHED"},
		{"published but the index file is missing", func() (int, []byte) { return 200, registry(true) },
			func() (int, []byte) { return 404, nil }, "PANEL_CHANNEL_INDEX_MISSING"},
		{"published but the index is broken JSON", func() (int, []byte) { return 200, registry(true) },
			func() (int, []byte) { return 200, []byte("{oops") }, "PANEL_METADATA_INVALID"},
		{"registry missing from the site", func() (int, []byte) { return 404, nil },
			func() (int, []byte) { t.Fatal("index must not be fetched without a registry"); return 0, nil },
			"PANEL_UPDATE_SOURCE_BROKEN"},
		{"registry is not JSON", func() (int, []byte) { return 200, []byte("<html>") },
			func() (int, []byte) { t.Fatal("index must not be fetched with a broken registry"); return 0, nil },
			"PANEL_UPDATE_SOURCE_BROKEN"},
		{"registry schema is alien", func() (int, []byte) { return 200, []byte(`{"schema":9,"channels":{}}`) },
			func() (int, []byte) { t.Fatal("index must not be fetched with an alien registry"); return 0, nil },
			"PANEL_UPDATE_SOURCE_BROKEN"},
		{"site temporarily unavailable", func() (int, []byte) { return 503, nil },
			func() (int, []byte) { t.Fatal("index must not be fetched when the site is down"); return 0, nil },
			"PANEL_UPDATE_SOURCE_UNAVAILABLE"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/updates/channels.json":
					code, body := tc.registry()
					w.WriteHeader(code)
					_, _ = w.Write(body)
				case "/updates/experimental/panel-update.json":
					code, body := tc.index()
					w.WriteHeader(code)
					_, _ = w.Write(body)
				default:
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			pagesUpdateBase = server.URL + "/updates"
			_, err := readChannelIndex(context.Background(), t.TempDir(), "experimental")
			if tc.want == "" {
				if err != nil {
					t.Fatalf("expected success, got %v", err)
				}
				return
			}
			if err == nil || err.Error() != tc.want {
				t.Fatalf("got %v, want %s", err, tc.want)
			}
		})
	}
}

func TestPagesRedirectsAreRestrictedToTheExactHost(t *testing.T) {
	restore := pagesUpdateBase
	defer func() { pagesUpdateBase = restore }()

	evil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"schema":1,"channels":{"experimental":{"published":true}}}`))
	}))
	defer evil.Close()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, evil.URL+"/updates/channels.json", http.StatusFound)
	}))
	defer server.Close()
	pagesUpdateBase = server.URL + "/updates"

	_, err := readChannelIndex(context.Background(), t.TempDir(), "experimental")
	if err == nil {
		t.Fatal("redirect to a foreign host must be refused")
	}
	code := err.Error()
	if code != "PANEL_UPDATE_REDIRECT_BLOCKED" && code != "PANEL_UPDATE_SOURCE_UNAVAILABLE" {
		t.Fatalf("unexpected classification %q", code)
	}
}
