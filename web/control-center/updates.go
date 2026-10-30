package main

// One fixed update action. The canonical shell transaction owns all runtime
// mutation/locking/recovery; HTTP never supplies commands, arguments or URLs.
import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type updateAsset struct {
	Version string
	Release int
}
type updateCheck struct {
	State                   string `json:"state"`
	Time                    string `json:"timestamp"`
	Architecture            string `json:"architecture,omitempty"`
	CurrentVersion          string `json:"current_version,omitempty"`
	AvailableVersion        string `json:"available_version,omitempty"`
	PackageRelease          int    `json:"package_release,omitempty"`
	Relation                string `json:"relation,omitempty"`
	InstalledPackageVersion string `json:"installed_package_version,omitempty"`
	RecordedPackageRelease  int    `json:"recorded_package_release,omitempty"`
	ErrorCode               string `json:"error_code,omitempty"`
}
type updateOperation struct {
	Component string `json:"component,omitempty"`
	ID        string `json:"id,omitempty"`
	State     string `json:"state"`
	Time      string `json:"timestamp"`
	Outcome   string `json:"outcome,omitempty"`
	ExitCode  *int   `json:"exit_code,omitempty"`
	ErrorCode string `json:"error_code,omitempty"`
}

var stableVersion = regexp.MustCompile(`^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$`)
var assetNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.+-]{1,240}$`)

func numericVersion(v string) ([3]int, bool) {
	var out [3]int
	if !stableVersion.MatchString(v) {
		return out, false
	}
	for i, s := range strings.Split(v, ".") {
		out[i], _ = strconv.Atoi(s)
	}
	return out, true
}
func compareRuntimeVersions(current, available string) string {
	c, ok := numericVersion(current)
	if !ok {
		return "unknown"
	}
	a, ok := numericVersion(available)
	if !ok {
		return "unknown"
	}
	for i := range a {
		if a[i] > c[i] {
			return "newer"
		}
		if a[i] < c[i] {
			return "older"
		}
	}
	return "same_runtime"
}
func selectUpdateAsset(raw []byte, arch string) (updateAsset, error) {
	fail := errors.New("UPDATE_METADATA_INVALID")
	if len(raw) > 1024*1024 {
		return updateAsset{}, fail
	}
	if arch != "mipsel-3.4" && arch != "mips-3.4" && arch != "armv7-3.2" && arch != "aarch64-3.10" {
		return updateAsset{}, fail
	}
	var doc struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			ID    int64  `json:"id"`
			Name  string `json:"name"`
			State string `json:"state"`
			Size  int64  `json:"size"`
			URL   string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if json.Unmarshal(raw, &doc) != nil || doc.Tag != "latest" || doc.Draft || doc.Prerelease || len(doc.Assets) == 0 || len(doc.Assets) > 256 {
		return updateAsset{}, fail
	}
	ids, names := map[int64]bool{}, map[string]bool{}
	selected := updateAsset{}
	for _, a := range doc.Assets {
		if a.ID < 1 || ids[a.ID] || names[a.Name] || !assetNamePattern.MatchString(a.Name) || a.State != "uploaded" || a.URL != "https://github.com/saymer-alt/entware-go/releases/download/latest/"+a.Name {
			return updateAsset{}, fail
		}
		ids[a.ID] = true
		names[a.Name] = true
		if strings.HasPrefix(a.Name, "mihomo_") && a.Size <= 0 {
			return updateAsset{}, fail
		}
		suffix := "_" + arch + ".ipk"
		if !strings.HasPrefix(a.Name, "mihomo_") || strings.HasPrefix(a.Name, "mihomo_nohf_") || !strings.HasSuffix(a.Name, suffix) {
			continue
		}
		version := strings.TrimSuffix(strings.TrimPrefix(a.Name, "mihomo_"), suffix)
		split := strings.LastIndex(version, "-")
		if split < 1 {
			return updateAsset{}, fail
		}
		engine, release := version[:split], version[split+1:]
		if _, ok := numericVersion(engine); !ok || len(release) > 9 || release == "" || release[0] == '0' {
			return updateAsset{}, fail
		}
		r, err := strconv.Atoi(release)
		if err != nil || r < 1 {
			return updateAsset{}, fail
		}
		relation := compareRuntimeVersions(selected.Version, engine)
		if selected.Version == "" || relation == "newer" || relation == "same_runtime" && r > selected.Release {
			selected = updateAsset{engine, r}
		}
	}
	if selected.Version == "" {
		return selected, fail
	}
	return selected, nil
}
func updateClient() *http.Client { return updateClientForRoot("/opt") }
func updateClientForRoot(root string) *http.Client {
	roots, err := x509.SystemCertPool()
	if err != nil || roots == nil {
		roots = x509.NewCertPool()
	}
	// Entware keeps its ca-bundle outside Go's Linux default search locations.
	// Append only protected root-owned data; never disable TLS verification.
	if data, err := inventoryFile(root, "etc/ssl/certs/ca-certificates.crt", 2*1024*1024, false); err == nil {
		roots.AppendCertsFromPEM(data)
	}
	return &http.Client{Timeout: 8 * time.Second, Transport: &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12, CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256}}, DialContext: (&net.Dialer{Timeout: 2 * time.Second}).DialContext, DisableKeepAlives: true}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func fetchUpdateMetadata(ctx context.Context, client *http.Client, target string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "KAS-Control-Center")
	response, err := client.Do(req)
	if err != nil {
		return nil, errors.New("UPDATE_CHECK_FAILED")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return nil, errors.New("UPDATE_CHECK_FAILED")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1024*1024+1))
	if err != nil || len(raw) > 1024*1024 {
		return nil, errors.New("UPDATE_METADATA_INVALID")
	}
	return raw, nil
}
func (a *app) fetchUpdateCheck(ctx context.Context) (updateCheck, error) {
	arch := map[string]string{"arm64": "aarch64-3.10", "arm": "armv7-3.2", "mipsle": "mipsel-3.4", "mips": "mips-3.4"}[runtime.GOARCH]
	if arch == "" {
		return updateCheck{}, errors.New("UNSUPPORTED_ARCHITECTURE")
	}
	raw, err := fetchUpdateMetadata(ctx, updateClient(), "https://api.github.com/repos/saymer-alt/entware-go/releases/tags/latest")
	if err != nil {
		return updateCheck{}, err
	}
	asset, err := selectUpdateAsset(raw, arch)
	if err != nil {
		return updateCheck{}, err
	}
	local := a.runtimeStatus(ctx)
	return enrichMihomoCheck("/opt", updateCheck{State: "AVAILABLE", Architecture: arch, CurrentVersion: local.Mihomo.Version, AvailableVersion: asset.Version, PackageRelease: asset.Release, Relation: compareRuntimeVersions(local.Mihomo.Version, asset.Version)}), nil
}
func updateCommand(script []byte) (int, error) {
	cmd := exec.Command("sh", "-s")
	cmd.Stdin = bytes.NewReader(script)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	// No request context or kill timeout: do not interrupt canonical rollback.
	err := cmd.Run()
	if err == nil {
		return 0, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode(), err
	}
	return -1, err
}
func mihomoBinaryDigest(root string) string {
	path := ""
	for _, name := range []string{"bin/mihomo", "sbin/mihomo"} {
		candidate := filepath.Join(root, name)
		st, err := os.Lstat(candidate)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil || !st.Mode().IsRegular() || !inventoryOwned(st) || st.Mode().Perm()&0022 != 0 || st.Size() > 128*1024*1024 || path != "" {
			return ""
		}
		path = candidate
	}
	if path == "" {
		return ""
	}
	for dir := filepath.Dir(path); ; dir = filepath.Dir(dir) {
		st, err := os.Lstat(dir)
		if err != nil || !st.IsDir() || !inventoryOwned(st) || st.Mode().Perm()&0022 != 0 {
			return ""
		}
		if dir == root {
			break
		}
		if dir == filepath.Dir(dir) {
			return ""
		}
	}
	before, err := os.Lstat(path)
	if err != nil {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	current, err := f.Stat()
	if err != nil || !os.SameFile(before, current) {
		return ""
	}
	hash := sha256.New()
	n, err := io.Copy(hash, io.LimitReader(f, 128*1024*1024+1))
	if err != nil || n != before.Size() {
		return ""
	}
	after, err := os.Lstat(path)
	if err != nil || !os.SameFile(before, after) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return ""
	}
	return hex.EncodeToString(hash.Sum(nil))
}
func updateJSON(w http.ResponseWriter, code int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(data)
}
func (a *app) validUpdateRequest(w http.ResponseWriter, r *http.Request, confirm string) bool {
	if r.Method != http.MethodPost {
		updateJSON(w, 405, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "METHOD_NOT_ALLOWED"})
		return false
	}
	if r.Header.Get("Origin") != a.expectedOrigin(r.Host) || r.Header.Get("Content-Type") != "application/json" || r.Header.Get("X-KAS-Confirm") != confirm {
		updateJSON(w, 403, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "REQUEST_BLOCKED"})
		return false
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		updateJSON(w, 403, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "REQUEST_BLOCKED"})
		return false
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 32))
	var body map[string]json.RawMessage
	if err != nil || json.Unmarshal(raw, &body) != nil || body == nil || len(body) != 0 {
		updateJSON(w, 400, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "INVALID_BODY"})
		return false
	}
	return true
}
func (a *app) handleUpdateCheck(w http.ResponseWriter, r *http.Request) {
	if !a.validUpdateRequest(w, r, "check-updates") {
		return
	}
	a.mu.Lock()
	if a.panelUpdateBusy() || a.updateChecking || a.importRunning || a.running || a.shuttingDown {
		a.mu.Unlock()
		updateJSON(w, 409, updateCheck{State: "UNKNOWN", Time: now(), ErrorCode: "BUSY"})
		return
	}
	a.updateChecking = true
	a.lastUpdateCheck = updateCheck{}
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.updateChecking = false; a.mu.Unlock() }()
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	result, err := a.checkUpdates(ctx)
	result.Time = now()
	if err != nil {
		updateJSON(w, 502, updateCheck{State: "UNKNOWN", Time: now(), ErrorCode: "UPDATE_CHECK_FAILED"})
		return
	}
	a.mu.Lock()
	a.lastUpdateCheck = result
	a.mu.Unlock()
	updateJSON(w, 200, result)
}
func (a *app) handleMihomoUpdate(w http.ResponseWriter, r *http.Request) {
	if !a.validUpdateRequest(w, r, "update-mihomo") {
		return
	}
	a.mu.Lock()
	if a.panelUpdateBusy() || a.importRunning || a.running || a.shuttingDown || a.updateChecking {
		a.mu.Unlock()
		updateJSON(w, 409, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "BUSY"})
		return
	}
	checked, err := time.Parse(time.RFC3339, a.lastUpdateCheck.Time)
	if err != nil || time.Since(checked) > 10*time.Minute || a.lastUpdateCheck.State != "AVAILABLE" || !mihomoUpdateOffered(a.lastUpdateCheck.Relation) {
		a.mu.Unlock()
		updateJSON(w, 409, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "CHECK_REQUIRED"})
		return
	}
	if len(a.updater) == 0 {
		a.mu.Unlock()
		updateJSON(w, 503, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "UPDATER_UNAVAILABLE"})
		return
	}
	id := make([]byte, 12)
	if _, err := rand.Read(id); err != nil {
		a.mu.Unlock()
		updateJSON(w, 503, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "STAGING_FAILED"})
		return
	}
	entry := updateOperation{ID: hex.EncodeToString(id), Component: "mihomo", State: "RUNNING", Time: now()}
	a.importRunning = true
	a.updateResult = entry
	a.lastUpdateCheck = updateCheck{}
	a.mu.Unlock()
	go func(entry updateOperation) {
		before := a.updateDigest()
		exit, err := a.runUpdate(a.updater)
		after := a.updateDigest()
		entry.Time = now()
		entry.ExitCode = &exit
		if err != nil || exit != 0 {
			entry.State = "FAIL"
			entry.ErrorCode = "UPDATE_FAILED"
		} else {
			entry.State = "OK"
			entry.Outcome = "UNVERIFIED"
			if before != "" && after != "" {
				entry.Outcome = "UNCHANGED"
				if before != after {
					entry.Outcome = "CHANGED"
				}
			}
		}
		a.mu.Lock()
		a.updateResult = entry
		a.importRunning = false
		a.mu.Unlock()
	}(entry)
	updateJSON(w, 202, entry)
}
func (a *app) handleUpdateOperation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		updateJSON(w, 405, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "METHOD_NOT_ALLOWED"})
		return
	}
	a.mu.Lock()
	result := a.updateResult
	a.mu.Unlock()
	if result.State == "" {
		result = updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "NO_OPERATION"}
	}
	updateJSON(w, 200, result)
}
